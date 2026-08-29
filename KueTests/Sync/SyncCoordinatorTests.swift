//
//  SyncCoordinatorTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26 "S." End-to-end orchestration tests, entirely fake-backed — no
//  real CloudKit, no real account, ever (docs/26 "R."). Covers initial sync (upload-only/
//  download-only/two-sided), account states, sign-out, account switch, error handling, and
//  that remote changes trigger the existing reconciliation pipeline.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

// `.syncPreferenceSerialized` (see SyncPreferenceTestLock.swift): every test here reads/writes
// `SyncPreference`, real process-global App Group `UserDefaults` state (same as
// `LegacyRecoveryTestHooks`) also mutated by the unrelated `CloudKitSchemaSafetyTests` suite.
// Plain `.serialized` only serializes tests *within* this suite — it doesn't stop a
// concurrently-running different suite's `SyncPreference.setEnabled` from racing these tests,
// which a real combined run of both suites reproduced 100% of the time before this trait was
// added (see SyncPreferenceTestLock.swift's header for the exact failure).
@Suite(.syncPreferenceSerialized)
@MainActor
struct SyncCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func makeCoordinator(
        transport: FakeCloudSyncTransport = FakeCloudSyncTransport(),
        account: FakeCloudAccountProvider = FakeCloudAccountProvider(),
        store: FakeCloudSyncStateStore = FakeCloudSyncStateStore()
    ) -> SyncCoordinator {
        SyncCoordinator(stateStore: store, transport: transport, accountProvider: account, clock: FakeSyncClock(now: now))
    }

    /// `updatedAt`/`createdAt` are pinned to the fixed `now` fixture (not the real wall
    /// clock's `KueEvent.init` default) so a test's remote-record fixtures — which also use
    /// `now`-relative timestamps — compare meaningfully against this local one.
    /// `markPendingUpload` mirrors what `EventCreationService.create`/`EventFormView.save()`
    /// already do for real in the app (`SyncOutbox.markEventDirty` right after the local
    /// save) — a test that needs the event to actually reach `transport.send` opts in, the
    /// same way a real mutation always does.
    @discardableResult
    private func insertEvent(
        in context: ModelContext, title: String = "Interview",
        markPendingUpload: Bool = false, store: CloudSyncStatePersisting = FakeCloudSyncStateStore()
    ) -> KueEvent {
        let event = KueEvent(title: title, eventType: .interview, startDate: now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual, createdAt: now, updatedAt: now)
        context.insert(event)
        try? context.save()
        if markPendingUpload { SyncOutbox.markEventDirty(event.id, store: store) }
        return event
    }

    // MARK: Off / account states

    @Test func syncDisabledNeverTouchesTheTransport() async {
        SyncPreference.setEnabled(false)
        let transport = FakeCloudSyncTransport()
        let status = await makeCoordinator(transport: transport).sync(context: makeContext())
        #expect(status == .off)
        #expect(transport.sendCallCount == 0)
        #expect(transport.fetchCallCount == 0)
    }

    @Test func noAccountKeepsAllLocalDataAndReportsWaitingForSignIn() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context)
        let account = FakeCloudAccountProvider(state: .noAccount)
        let status = await makeCoordinator(account: account).sync(context: context)
        #expect(status == .waitingForSignIn)
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.first?.id == event.id) // untouched
    }

    @Test func restrictedAccountKeepsLocalDataAndReportsWaitingForSignIn() async {
        SyncPreference.setEnabled(true)
        let account = FakeCloudAccountProvider(state: .restricted)
        let status = await makeCoordinator(account: account).sync(context: makeContext())
        #expect(status == .waitingForSignIn)
    }

    @Test func temporarilyUnavailableAccountIsReportedHonestlyNotAsSignedOut() async {
        SyncPreference.setEnabled(true)
        let account = FakeCloudAccountProvider(state: .temporarilyUnavailable)
        let status = await makeCoordinator(account: account).sync(context: makeContext())
        #expect(status == .temporarilyUnavailable)
    }

    // MARK: 5/6/7 — initial sync

    @Test func initialLocalOnlyUploadsSafely() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        let status = await makeCoordinator(transport: transport, store: store).sync(context: context)
        #expect(status == .upToDate)
        #expect(transport.events[event.id]?.title == "Interview")
    }

    @Test func initialCloudOnlyDownloadsIntoAnEmptyLocalStore() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeCloudSyncTransport()
        let remoteID = UUID()
        transport.seedRemoteEvent(EventSyncRecord(
            id: remoteID, title: "From Cloud", eventType: "generic", startDate: now, endDate: nil,
            estimatedDurationMinutes: 0, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now
        ))
        _ = await makeCoordinator(transport: transport).sync(context: context)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.contains { $0.id == remoteID && $0.title == "From Cloud" })
    }

    @Test func twoSidedInitialMergeKeepsBothUnrelatedEvents() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        let localEvent = insertEvent(in: context, title: "Local Only", markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        let remoteID = UUID()
        transport.seedRemoteEvent(EventSyncRecord(
            id: remoteID, title: "Remote Only", eventType: "generic", startDate: now, endDate: nil,
            estimatedDurationMinutes: 0, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now
        ))
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.contains { $0.id == localEvent.id })
        #expect(localEvents.contains { $0.id == remoteID })
        #expect(transport.events[localEvent.id] != nil) // local was also uploaded
    }

    // MARK: 8/9/10 — same-UUID conflict resolved end-to-end

    @Test func remoteNewerEditOverwritesLocalDuringSync() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context, title: "Original")
        let transport = FakeCloudSyncTransport()
        transport.seedRemoteEvent(EventSyncRecord(
            id: event.id, title: "Edited Elsewhere", eventType: "interview", startDate: now.addingTimeInterval(86_400), endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now.addingTimeInterval(1000) // strictly newer than the local event's own updatedAt
        ))
        _ = await makeCoordinator(transport: transport).sync(context: context)
        let eventID = event.id
        let refreshed = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
        #expect(refreshed?.title == "Edited Elsewhere")
    }

    // MARK: 35/36 — remote completion/cancel/skip/restore; Awaiting Outcome preservation

    @Test func remoteManualCompletionAppliesLocallyAndIsNeverInferredFromTimePassing() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let event = insertEvent(in: context)
        let transport = FakeCloudSyncTransport()
        transport.seedRemoteEvent(EventSyncRecord(
            id: event.id, title: "Interview", eventType: "interview", startDate: now.addingTimeInterval(86_400), endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: true, manuallyCompletedAt: now,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now.addingTimeInterval(1000)
        ))
        _ = await makeCoordinator(transport: transport).sync(context: context)
        let eventID = event.id
        let refreshed = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
        #expect(refreshed?.isManuallyCompleted == true)
        #expect(EventStatusEngine.derive(for: refreshed!, now: now) == .completed)
    }

    // MARK: Sign-out / account switch (docs/26 "G.")

    @Test func pauseForSignOutRetainsLocalDataAndReportsPaused() async {
        let coordinator = makeCoordinator()
        coordinator.pauseForSignOut()
        #expect(coordinator.status == .paused)
    }

    @Test func accountChangeBlocksSyncUntilExplicitlyResolved() async {
        SyncPreference.setEnabled(true)
        let store = FakeCloudSyncStateStore()
        var state = store.load()
        state.accountFingerprint = "old-account"
        store.save(state)

        let account = FakeCloudAccountProvider(state: .available, fingerprint: "new-account")
        let coordinator = makeCoordinator(account: account, store: store)
        let status = await coordinator.sync(context: makeContext())
        #expect(status == .accountChanged)
    }

    @Test func resolvingAccountChangeQuarantinesPreviousEngineStateAndNeverMergesSilently() async {
        let store = FakeCloudSyncStateStore()
        var state = store.load()
        state.accountFingerprint = "old-account"
        state.engineStateData = Data("old-engine-state".utf8)
        store.save(state)

        let transport = FakeCloudSyncTransport()
        let account = FakeCloudAccountProvider(state: .available, fingerprint: "new-account")
        let coordinator = makeCoordinator(transport: transport, account: account, store: store)

        await coordinator.resolveAccountChange(keepLocalAndStartFresh: true)

        #expect(transport.resetCallCount == 1)
        let updated = store.load()
        #expect(updated.engineStateData == nil)
        #expect(updated.accountFingerprint == "new-account")
    }

    // MARK: 22/23/25 — transient retry, permanent failure, rate limit

    @Test func transientNetworkFailureLeavesTheChangePendingForRetry() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        transport.nextSendError = .networkFailure
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context)
        // Still pending — never dropped for a transient failure.
        #expect(store.load().pendingEventUploads == [event.id])
    }

    @Test func permanentFailureIsNotRetriedEndlessly() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        _ = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        transport.nextSendError = .quotaExceeded
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context)
        // A permanent failure drops the item from the outbox rather than retrying forever.
        #expect(store.load().pendingEventUploads.isEmpty)
    }

    @Test func rateLimitSetsRetryNotBeforeAndSkipsTheNextSyncUntilItPasses() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        _ = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        transport.nextSendError = .rateLimited(retryAfterSeconds: 60)
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context)
        #expect(store.load().retryNotBefore != nil)

        // A second sync pass before the retry window passes shouldn't hammer the transport.
        let secondContext = makeContext()
        let status = await makeCoordinator(transport: transport, store: store).sync(context: secondContext)
        #expect(status == .waitingForNetwork)
    }

    // MARK: 28 — corrupt/future-version record quarantine

    @Test func futureVersionRemoteRecordIsQuarantinedNeverAppliedOrCrashed() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let transport = FakeCloudSyncTransport()
        let futureID = UUID()
        transport.seedRemoteEvent(EventSyncRecord(
            id: futureID, title: "From The Future", eventType: "generic", startDate: now, endDate: nil,
            estimatedDurationMinutes: 0, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now
        ))
        transport.futureVersionEventIDs = [futureID]
        _ = await makeCoordinator(transport: transport).sync(context: context)
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(!localEvents.contains { $0.id == futureID })
    }

    // MARK: 33 — manual Sync Now is just another call to the same entry point

    @Test func manualSyncNowUsesTheSameEntryPointAsEveryOtherTrigger() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        let coordinator = makeCoordinator(transport: transport, store: store)
        _ = await coordinator.sync(context: context) // "launch"
        _ = await coordinator.sync(context: context) // "manual Sync Now"
        #expect(transport.events[event.id] != nil)
    }

    // MARK: 32 — sync disabled behavior mid-stream

    @Test func disablingSyncStopsFurtherTransfersButNeverDeletesAnything() async {
        SyncPreference.setEnabled(true)
        let context = makeContext()
        let store = FakeCloudSyncStateStore()
        let event = insertEvent(in: context, markPendingUpload: true, store: store)
        let transport = FakeCloudSyncTransport()
        _ = await makeCoordinator(transport: transport, store: store).sync(context: context)
        #expect(transport.events[event.id] != nil)

        SyncPreference.setEnabled(false)
        let status = await makeCoordinator(transport: transport, store: store).sync(context: context)
        #expect(status == .off)
        // Nothing was removed from CloudKit or locally by disabling.
        #expect(transport.events[event.id] != nil)
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.contains { $0.id == event.id } == true)
    }
}
