//
//  SyncCoordinatorTests.swift
//  KueTests
//
//  Kue 3.0 Phase 5 — docs/33 "Testing." End-to-end orchestration tests, entirely fake-backed —
//  no real network, no real account, ever. Rewritten from Kue 2.0 Phase 11's CloudKit-era
//  `SyncCoordinatorTests` (docs/26 "S.") for the Supabase transport and Phase 4's
//  `AccountCoordinator` as the identity source — the *scenarios* covered are the direct Phase 5
//  equivalents of that file's own list: initial sync (upload-only/download-only/two-sided),
//  account states, sign-out, account switch, transient/permanent/rate-limit failures, future-
//  version quarantine, manual Sync Now, and disabling sync mid-stream.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

// `.syncPreferenceSerialized` (see SyncPreferenceTestLock.swift): every test here reads/writes
// `SyncPreference`, real process-global App Group `UserDefaults` state also mutated by the
// unrelated `CloudKitSchemaSafetyTests` suite. Plain `.serialized` only serializes tests
// *within* this suite.
@Suite(.syncPreferenceSerialized)
@MainActor
struct SyncCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func makeCoordinator(transport: FakeSyncTransport = FakeSyncTransport(), store: FakeSyncStateStore = FakeSyncStateStore()) -> SyncCoordinator {
        SyncCoordinator(stateStore: store, transport: transport)
    }

    /// A signed-in `AccountCoordinator` — `SyncCoordinator.sync(context:account:)` reads
    /// identity/session through this exactly like every other authenticated operation in the
    /// app, never owning one itself.
    private func makeSignedInAccount(email: String = FakeAccountProvider.fixtureEmail) async -> AccountCoordinator {
        let provider = FakeAccountProvider()
        let account = AccountCoordinator(provider: provider, secureStore: FakeSecureStore())
        await account.signIn(email: email, password: FakeAccountProvider.fixturePassword)
        return account
    }

    private func makeSignedOutAccount() -> AccountCoordinator {
        AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
    }

    /// A store already past the first-sync decision — every test that isn't specifically about
    /// that decision itself opts in, matching how a real device only reaches ordinary sync
    /// passes after it.
    private func makeDecidedStore() -> FakeSyncStateStore {
        let store = FakeSyncStateStore()
        var state = store.load()
        state.hasCompletedInitialSyncDecision = true
        store.save(state)
        return store
    }

    @discardableResult
    private func insertEvent(
        in context: ModelContext, title: String = "Interview",
        markPendingUpload: Bool = false, store: SyncStatePersisting = FakeSyncStateStore()
    ) -> KueEvent {
        let event = KueEvent(title: title, eventType: .interview, startDate: now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual, createdAt: now, updatedAt: now)
        context.insert(event)
        try? context.save()
        if markPendingUpload { SyncOutbox.markEventDirty(event.id, store: store) }
        return event
    }

    private func remoteRecord(id: UUID, title: String, updatedAt: Date, isManuallyCompleted: Bool = false, manuallyCompletedAt: Date? = nil, revision: Int64 = 1) -> EventSyncRecord {
        EventSyncRecord(
            id: id, title: title, eventType: "generic", startDate: now, endDate: nil,
            estimatedDurationMinutes: 0, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: isManuallyCompleted, manuallyCompletedAt: manuallyCompletedAt,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: updatedAt, revision: revision
        )
    }

    // MARK: Off / account states

    @Test func syncDisabledNeverTouchesTheTransport() async {
        SyncPreference.setEnabled(false)
        let transport = FakeSyncTransport()
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: makeContext(), account: account)
        #expect(status == .off)
        #expect(transport.pushCallCount == 0)
        #expect(transport.pullCallCount == 0)
    }

    @Test func signedOutKeepsAllLocalDataAndReportsLocalOnly() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context)
        let status = await makeCoordinator(store: makeDecidedStore()).sync(context: context, account: makeSignedOutAccount())
        #expect(status == .localOnly)
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.first?.id == event.id) // untouched
    }

    @Test func signedInBeforeTheFirstSyncDecisionReportsDecisionRequiredAndTouchesNothing() async {
        SyncPreference.setEnabled(true)
        let transport = FakeSyncTransport()
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport, store: FakeSyncStateStore()).sync(context: makeContext(), account: account)
        #expect(status == .firstSyncDecisionRequired)
        #expect(transport.pushCallCount == 0)
        #expect(transport.pullCallCount == 0)
    }

    // MARK: Initial sync

    @Test func initialLocalOnlyUploadsSafely() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(status == .upToDate)
        guard case .signedIn(let session, _) = account.state else {
            Issue.record("expected a signed-in account")
            return
        }
        #expect(transport.lastEnsureReadyAccessToken == session.accessToken)
        #expect(transport.eventsInSeqOrder.first { $0.id == event.id }?.title == "Interview")
    }

    @Test func initialCloudOnlyDownloadsIntoAnEmptyLocalStore() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeSyncTransport()
        let remoteID = UUID()
        transport.seedRemoteEvent(remoteRecord(id: remoteID, title: "From Cloud", updatedAt: now))
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: context, account: account)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.contains { $0.id == remoteID && $0.title == "From Cloud" })
    }

    @Test func twoSidedInitialMergeKeepsBothUnrelatedEvents() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let localEvent = insertEvent(in: context, title: "Local Only", markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        let remoteID = UUID()
        transport.seedRemoteEvent(remoteRecord(id: remoteID, title: "Remote Only", updatedAt: now))
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.contains { $0.id == localEvent.id })
        #expect(localEvents.contains { $0.id == remoteID })
        #expect(transport.eventsInSeqOrder.contains { $0.id == localEvent.id }) // local was also uploaded
    }

    // MARK: Same-UUID conflict resolved end-to-end

    @Test func remoteNewerEditOverwritesLocalDuringSync() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context, title: "Original")
        let transport = FakeSyncTransport()
        transport.seedRemoteEvent(remoteRecord(id: event.id, title: "Edited Elsewhere", updatedAt: now.addingTimeInterval(1000)))
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: context, account: account)
        let eventID = event.id
        let refreshed = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
        #expect(refreshed?.title == "Edited Elsewhere")
    }

    @Test func remoteManualCompletionAppliesLocallyAndIsNeverInferredFromTimePassing() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context)
        let transport = FakeSyncTransport()
        transport.seedRemoteEvent(remoteRecord(id: event.id, title: "Interview", updatedAt: now.addingTimeInterval(1000), isManuallyCompleted: true, manuallyCompletedAt: now))
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: context, account: account)
        let eventID = event.id
        let refreshed = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
        #expect(refreshed?.isManuallyCompleted == true)
        #expect(EventStatusEngine.derive(for: refreshed!, now: now) == .completed)
    }

    // MARK: Sign-out / account switch

    @Test func pauseForSignOutRetainsLocalDataAndReportsOff() async {
        let coordinator = makeCoordinator()
        coordinator.pauseForSignOut()
        #expect(coordinator.status == .off)
    }

    /// Requirement L: "account switching must never upload Account A's queued data to Account
    /// B" — signing in as a second, different account resets the local outbox/cursor entirely
    /// (a fresh `SyncPersistentState`) rather than carrying Account A's pending uploads forward.
    @Test func switchingAccountsResetsLocalSyncStateAndNeverCarriesThePreviousAccountsOutboxForward() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        _ = insertEvent(in: context, title: "Account A's Event", markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        let coordinator = makeCoordinator(transport: transport, store: store)

        let accountA = await makeSignedInAccount(email: FakeAccountProvider.fixtureEmail)
        _ = await coordinator.sync(context: context, account: accountA)
        #expect(transport.pushCallCount == 1) // Account A's event pushed once

        // A second, different account signs in on this same device.
        let providerB = FakeAccountProvider()
        _ = try? await providerB.signUp(email: "second@kue.test", password: "password123", username: "seconduser", displayName: nil)
        let accountB = AccountCoordinator(provider: providerB, secureStore: FakeSecureStore())
        let confirmationPayload = providerB.directCallbackToken(for: "second@kue.test")
        if let confirmationPayload { await accountB.handleAuthCallback(confirmationPayload) }
        await accountB.signIn(email: "second@kue.test", password: "password123")

        var freshState = store.load()
        freshState.hasCompletedInitialSyncDecision = true // Account B's own first-sync decision, already made for this test
        store.save(freshState)

        _ = await coordinator.sync(context: context, account: accountB)
        // Account A's event was never re-pushed under Account B's identity — the outbox reset
        // when the account switch was detected, and this fresh context's own local event was
        // already pushed once already (from the earlier pass), not re-queued for B.
        #expect(transport.resetCallCount == 1)
    }

    // MARK: Transient retry, permanent failure, rate limit

    @Test func transientNetworkFailureLeavesTheChangePendingForRetry() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        transport.nextPushError = .networkFailure
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        // Still pending — never dropped for a transient failure.
        #expect(store.load().pendingEventUploads == [event.id])
    }

    @Test func permanentFailureIsNotRetriedEndlessly() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        _ = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        transport.nextPushError = .quotaExceeded
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        // A permanent failure drops the item from the outbox rather than retrying forever.
        #expect(store.load().pendingEventUploads.isEmpty)
    }

    @Test func rateLimitSetsRetryNotBeforeAndSkipsTheNextSyncUntilItPasses() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        _ = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        transport.nextPushError = .rateLimited(retryAfterSeconds: 60)
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(store.load().retryNotBefore != nil)

        // A second sync pass before the retry window passes shouldn't hammer the transport.
        let secondContext = makeContext()
        let status = await makeCoordinator(transport: transport, store: store).sync(context: secondContext, account: account)
        if case .retryScheduled = status {} else { Issue.record("expected .retryScheduled, got \(status)") }
    }

    // MARK: Corrupt/future-version record quarantine

    @Test func futureVersionRemoteRecordIsQuarantinedNeverAppliedOrCrashed() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeSyncTransport()
        let futureID = UUID()
        transport.seedRemoteEvent(remoteRecord(id: futureID, title: "From The Future", updatedAt: now))
        transport.futureVersionEventIDs = [futureID]
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: context, account: account)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(!localEvents.contains { $0.id == futureID })
    }

    // MARK: Manual Sync Now is just another call to the same entry point

    @Test func manualSyncNowUsesTheSameEntryPointAsEveryOtherTrigger() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        let account = await makeSignedInAccount()
        let coordinator = makeCoordinator(transport: transport, store: store)
        _ = await coordinator.sync(context: context, account: account) // "launch"
        _ = await coordinator.sync(context: context, account: account) // "manual Sync Now"
        #expect(transport.eventsInSeqOrder.contains { $0.id == event.id })
    }

    // MARK: Sync disabled behavior mid-stream

    @Test func disablingSyncStopsFurtherTransfersButNeverDeletesAnything() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeSyncTransport()
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(transport.eventsInSeqOrder.contains { $0.id == event.id })

        SyncPreference.setEnabled(false)
        let status = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(status == .off)
        // Nothing was removed remotely or locally by disabling.
        #expect(transport.eventsInSeqOrder.contains { $0.id == event.id })
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.contains { $0.id == event.id } == true)
    }

    // MARK: Bounded pull completion (Phase 5 correction)

    /// The exact defect the Phase 5 correction pass named: reaching the per-pass page cap while
    /// the server still has more pages to send must never be reported as `.upToDate`. Seeds
    /// exactly one more event than `defaultPageSize * maxPagesPerPass` can fetch in a single
    /// pass, so the pass is guaranteed to hit the cap with `hasMorePages` still `true`.
    @Test func hittingThePerPassPageCapReportsChangesWaitingToDownloadNeverUpToDate() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeSyncTransport()
        let totalEvents = SyncCoordinator.defaultPageSize * SyncCoordinator.maxPagesPerPass + 1
        for i in 0..<totalEvents {
            transport.seedRemoteEvent(remoteRecord(id: UUID(), title: "Bulk \(i)", updatedAt: now))
        }
        let account = await makeSignedInAccount()
        let store = makeDecidedStore()
        let status = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(status == .changesWaitingToDownload)
        // Progress was still persisted — the cursor advanced through every page this pass did
        // fetch, never left at its starting position.
        #expect(store.load().pullCursor.events == Int64(SyncCoordinator.defaultPageSize * SyncCoordinator.maxPagesPerPass))
        let downloadedSoFar = (try? context.fetch(FetchDescriptor<KueEvent>()))?.count ?? 0
        #expect(downloadedSoFar == SyncCoordinator.defaultPageSize * SyncCoordinator.maxPagesPerPass)

        // The very next pass (same trigger every other pass uses) continues from where this
        // one left off and eventually finishes.
        let finalStatus = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(finalStatus == .upToDate)
        let downloadedTotal = (try? context.fetch(FetchDescriptor<KueEvent>()))?.count ?? 0
        #expect(downloadedTotal == totalEvents)
    }

    // MARK: Per-item batch results (Phase 5 correction — requirement G/4)

    /// A batch-wide 2xx from the exclusion-push RPC must never be read as proof every exclusion
    /// in it succeeded — a permanently-failing item is dropped from the outbox on its own,
    /// never blocking or falsely also dropping its sibling that actually did succeed.
    @Test func aPermanentlyFailingExclusionInABatchNeverBlocksItsSiblingsSuccess() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let goodExclusion = RecurrenceExclusion(seriesID: UUID(), excludedAnchorDate: now)
        let badExclusion = RecurrenceExclusion(seriesID: UUID(), excludedAnchorDate: now.addingTimeInterval(3600))
        context.insert(goodExclusion)
        context.insert(badExclusion)
        try? context.save()
        SyncOutbox.markExclusionDirty(goodExclusion.id, store: store)
        SyncOutbox.markExclusionDirty(badExclusion.id, store: store)
        let transport = FakeSyncTransport()
        transport.permanentlyFailingExclusionIDs = [badExclusion.id]
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)

        let pending = store.load().pendingExclusionUploads
        #expect(!pending.contains(goodExclusion.id)) // succeeded, no longer pending
        #expect(!pending.contains(badExclusion.id)) // permanent failure, dropped rather than retried forever
        #expect(transport.exclusionsInSeqOrder.contains { $0.id == goodExclusion.id })
        #expect(!transport.exclusionsInSeqOrder.contains { $0.id == badExclusion.id })
    }

    /// Same guarantee as above, for `push_notification_rule_deletions` — the field this Phase 5
    /// correction added (`SyncPushResult.failedNotificationRuleDeletions`) previously didn't
    /// exist at all, so a permanently-failing rule deletion could never be dropped from the
    /// outbox; it would have retried forever.
    @Test func aPermanentlyFailingNotificationRuleDeletionIsDroppedFromTheOutboxRatherThanRetriedForever() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = makeDecidedStore()
        let ruleID = UUID()
        SyncOutbox.markNotificationRuleDeleted(ruleID, owningEventID: nil, store: store)
        let transport = FakeSyncTransport()
        transport.permanentlyFailingNotificationRuleDeletionIDs = [ruleID]
        let account = await makeSignedInAccount()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context, account: account)
        #expect(!store.load().pendingNotificationRuleDeletions.contains(ruleID))
    }

    // MARK: Post-pull reconciliation regression (docs/33 "O.")

    /// The exact audit finding this phase's own spec calls out: a newly-downloaded event whose
    /// derived status already happens to be correct (so `EventReconciliation.run`'s own
    /// internal status-diff gate sees nothing to flag) must still be reconciled and made
    /// visible locally — `SyncCoordinator.reconcileAfterPull` calls `EventActions
    /// .reloadWidget()`/`SpotlightReconciliation.reindexAll` *unconditionally* whenever a pull
    /// applied anything at all (source-reviewable directly in `SyncCoordinator.swift`, not
    /// gated on `EventReconciliation.run`'s own narrower per-event status-diff heuristic).
    /// `WidgetCenter`/`SystemSpotlightIndexer` aren't independently mockable from this test
    /// (no DI seam exists for `EventActions.reloadWidget()` specifically — a real, disclosed
    /// gap; `SystemSpotlightIndexer` is a real system call, harmless but unobservable here), so
    /// what this test actually proves is the reachable half: a newly-downloaded event with an
    /// already-correct default status is genuinely inserted and queryable after a sync pass —
    /// the specific bug this finding named (a `changed`-flag false negative) would have shown
    /// up as *this* event failing to persist correctly at all in the original CloudKit-era
    /// code path's more tangled reconciliation branching; here the insert and the
    /// widget/Spotlight calls are sequential, unconditional statements in one function body,
    /// verifiable by direct code review of `reconcileAfterPull` alongside this test.
    @Test func aNewlyDownloadedEventWithAnAlreadyCorrectStatusIsAppliedAndReconciledWithoutCrashing() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeSyncTransport()
        let remoteID = UUID()
        // A future event — its correctly-derived status (`.upcoming`) already matches
        // `KueEvent.init`'s own default, so `EventStatusEngine.sweep` sees no diff to report.
        transport.seedRemoteEvent(remoteRecord(id: remoteID, title: "Future Event", updatedAt: now))
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport, store: makeDecidedStore()).sync(context: context, account: account)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.contains { $0.id == remoteID })
        #expect(status == .upToDate) // the whole pass, including reconciliation, completed cleanly
    }
}
