//
//  SyncCoordinator.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Architecture." The one orchestrator that owns cross-device sync —
//  app-only, `@MainActor` implicitly (this module's own `SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor`). Rewritten from Kue 2.0 Phase 11's CloudKit-era `SyncCoordinator` (docs/26) now
//  that Supabase is Kue's sole production sync backend (docs/33 "CloudKit retirement") — the
//  *sequencing* (ensure ready → upload pending → download remote → reconcile) is unchanged in
//  shape; what changed is the transport (`SupabaseSyncTransport`, keyset pull instead of a
//  single unpaginated fetch), the identity source (Phase 4's `AccountCoordinator`/
//  `AccountSession.user.id` instead of a CloudKit account fingerprint), and the conflict
//  authority (server-assigned revision/timestamp instead of a CloudKit record-change token).
//
//  Every step below is built from already-existing, already-tested pieces — this file adds no
//  new business rule of its own, only sequencing: `EventGraphMapper` (encode/decode),
//  `SyncConflictResolver` (pure decision), `EventReconciliation.run` (status/occurrence/widget/
//  Spotlight/Live-Activity), `NotificationEngine.reschedule`.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SyncCoordinator {
    /// A `var`, not `let` — `KueApp`/`KueMacApp` swap this for a fake-backed instance under
    /// `KueUITests`, the same "install a fake behind the one production singleton" pattern
    /// `FakeLiveActivityManager.makeFromLaunchArguments`/`SyncCoordinator`'s own Kue 2.0 Phase
    /// 11 precedent already establish.
    static var shared = SyncCoordinator()

    /// Exposed (not `private`) so Settings' sync section reads through the *same* store this
    /// coordinator itself uses — under `KueUITests`, that's the fake in-memory store, never the
    /// real `SystemSyncStateStore.shared` file.
    let stateStore: SyncStatePersisting
    private let transport: SyncTransporting

    private(set) var status: SyncStatus = .off
    private var isSyncing = false
    /// The account this device last synced under — compared against the *current* session's
    /// user id on every call to detect a switch (requirement L: "account switching must never
    /// upload Account A's queued data to Account B").
    private var lastSyncedAccountID: UUID?

    init(stateStore: SyncStatePersisting = SystemSyncStateStore.shared, transport: SyncTransporting = SyncCoordinator.defaultTransport) {
        self.stateStore = stateStore
        self.transport = transport
    }

    /// Requirement L: "missing Supabase configuration leaves the app fully local" — `nil`
    /// configuration resolves to `NullSyncTransport`, which fails closed on every operation;
    /// `SyncPreference.current.isEnabled` being forced off in that case (see `SyncPreference`)
    /// means this is never even reached in practice, but the transport itself is safe regardless.
    nonisolated private static var defaultTransport: SyncTransporting {
        SupabaseConfiguration.current.map { SupabaseSyncTransport(configuration: $0) } ?? NullSyncTransport()
    }

    /// Must match `UITestLaunchConfiguration.fakeSyncArgument` (KueUITests/) exactly.
    static let uiTestLaunchArgument = "-uiTestFakeSync"

    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SyncCoordinator? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        SyncPreference.setEnabled(true)
        // `hasCompletedInitialSyncDecision` starts `false` (a fresh `FakeSyncStateStore`'s own
        // default) — deliberately *not* pre-seeded `true` here, so `CloudSyncUITests` can drive
        // the real "Set Up Sync" → first-sync-decision flow exactly as a genuinely new account
        // would see it, rather than skipping straight to an already-decided toggle.
        return SyncCoordinator(stateStore: FakeSyncStateStore(), transport: FakeSyncTransport())
    }

    /// Not `private` — `SyncCoordinatorTests`/the Phase 5 sync benchmark reference these
    /// directly (via `@testable import`) to size a fixture that deterministically crosses the
    /// per-pass page cap, rather than hardcoding a duplicate "200 * 25" magic number that would
    /// silently drift out of sync with the real values.
    static let defaultPageSize = 200
    static let maxPagesPerPass = 25 // requirement U/Q: bounded work per sync pass, never an unbounded loop

    /// The one entry point every trigger (launch, scene activation, manual "Sync Now",
    /// background refresh, network/auth recovery) calls. Reentrancy-safe — a call that arrives
    /// while one is already running is a no-op, not a second concurrent pass.
    ///
    /// `account` is Phase 4's `AccountCoordinator` — this file never constructs or refreshes a
    /// session itself (requirement M: "avoid duplicated refresh logic"), only ever calls
    /// `account.refreshIfNeeded()`, the exact same deduplicated path every other authenticated
    /// operation in the app already goes through.
    @discardableResult
    func sync(context: ModelContext, account: AccountCoordinator, now: Date? = nil) async -> SyncStatus {
        let now = now ?? Date()
        guard SyncPreference.current.isEnabled else {
            status = .off
            return status
        }
        guard !isSyncing else { return status }
        isSyncing = true
        defer { isSyncing = false }

        // Requirement L: "no sync while signed out" — a truthful, non-alarming state, never an
        // error banner; local data remains fully usable regardless.
        guard case .signedIn(let session, _) = account.state else {
            status = .localOnly
            return status
        }

        // Account-switch guard, keyed per account (requirement L: "store sync cursors and
        // fingerprints per account... account switching must never upload Account A's queued
        // data to Account B"). Retargeting the state store's own `currentAccountID` is what
        // actually changes which on-disk file every subsequent `SyncOutbox`/`stateStore` call
        // in this pass (and every ordinary mutation call site elsewhere in the app) reads from.
        if let systemStore = stateStore as? SystemSyncStateStore, systemStore.currentAccountID != session.user.id {
            systemStore.currentAccountID = session.user.id
        }
        if let lastSyncedAccountID, lastSyncedAccountID != session.user.id {
            await transport.resetLocalAccountState()
            stateStore.save(SyncPersistentState()) // fresh cursor/outbox for the new account
        }
        lastSyncedAccountID = session.user.id

        var state = stateStore.load()

        // Requirement J: first-sync decision — never pushes/pulls anything until the user has
        // made an explicit choice for *this* account (`AccountFirstSyncDecisionView`).
        guard state.hasCompletedInitialSyncDecision else {
            status = .firstSyncDecisionRequired
            return status
        }

        if let retryNotBefore = state.retryNotBefore, retryNotBefore > now {
            status = .retryScheduled(at: retryNotBefore)
            return status
        }

        // Requirement L: "refresh expired sessions through AccountCoordinator... pause on
        // session expiration." A stale token is never sent — `refreshIfNeeded()` is the same
        // deduplicated path `loadProfile()`/`updateProfile(...)`/etc. already use.
        guard let activeSession = await account.refreshIfNeeded() else {
            status = .authenticationExpired
            return status
        }

        status = .syncing

        if case .failure(let error) = await transport.ensureReady(accessToken: activeSession.accessToken) {
            status = statusForTransportError(error, pendingCount: SyncOutbox.pendingChangeCount(store: stateStore))
            recordTransientFailureIfNeeded(error, now: now)
            return status
        }

        let pushSucceeded = await uploadPendingChanges(context: context, accessToken: activeSession.accessToken, now: now)
        let pullOutcome = await downloadRemoteChanges(context: context, accessToken: activeSession.accessToken, now: now)
        let pullSucceeded = pullOutcome != .failed

        state = stateStore.load()
        // A real bug this phase's own test-writing caught: `pushSucceeded`/`pullSucceeded`
        // being `true` only means "no *transport-level* failure" — a per-record rate-limit
        // response (still a "successful" push call) sets `state.retryNotBefore` *inside*
        // `uploadPendingChanges` above, and unconditionally clearing it here on "success"
        // immediately threw that fresh value away before this same pass even finished. Only
        // reset the failure-streak bookkeeping when this pass didn't *itself* just set a new
        // backoff window.
        if pushSucceeded && pullSucceeded && state.retryNotBefore == nil {
            state.lastSuccessfulSyncAt = now
            state.consecutiveFailureCount = 0
            stateStore.save(state)
        } else if pushSucceeded && pullSucceeded {
            state.lastSuccessfulSyncAt = now
            stateStore.save(state)
        }
        SyncOutbox.pruneExpiredTombstones(now: now, store: stateStore)

        let pending = SyncOutbox.pendingChangeCount(store: stateStore)
        if !pushSucceeded || !pullSucceeded {
            status = pending > 0 ? .partialFailure(count: pending) : .syncError("Sync didn't finish. It'll retry automatically.")
        } else if pullOutcome == .incomplete {
            // Phase 5 correction: the per-pass page cap was reached while the server still had
            // more to send — never reported as `.upToDate` even though nothing actually failed.
            // Progress is safely persisted (the cursor already advanced through every page this
            // pass fetched); the next sync pass continues right where this one left off.
            status = .changesWaitingToDownload
        } else {
            status = pending > 0 ? .changesWaitingToUpload(count: pending) : .upToDate
        }
        return status
    }

    // MARK: - Upload

    /// Returns `false` only on a transport-level failure that means the pass as a whole didn't
    /// complete (never merely "some records failed permanently," which is expected, logged into
    /// the outbox, and not itself a sync-pass failure).
    private func uploadPendingChanges(context: ModelContext, accessToken: String, now: Date) async -> Bool {
        let state = stateStore.load()
        var batch = SyncPushBatch()
        batch.eventSaves = state.pendingEventUploads.compactMap { id in
            guard let event = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })))?.first else { return nil }
            var record = EventGraphMapper.record(for: event)
            record.revision = state.knownEventRevisions[id] ?? 0
            return record
        }
        batch.eventDeletions = Array(state.pendingEventDeletions)
        batch.exclusionSaves = state.pendingExclusionUploads.compactMap { id in
            guard let exclusion = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == id })))?.first else { return nil }
            return EventGraphMapper.record(for: exclusion)
        }
        batch.notificationRuleDeletions = Array(state.pendingNotificationRuleDeletions)

        guard !batch.isEmpty else { return true }

        let result = await transport.push(batch, accessToken: accessToken)

        var updated = stateStore.load()
        updated.pendingEventUploads.subtract(result.succeededEventIDs)
        updated.pendingEventDeletions.subtract(result.succeededEventDeletionIDs)
        updated.pendingExclusionUploads.subtract(result.succeededExclusionIDs)
        updated.pendingNotificationRuleDeletions.subtract(result.succeededNotificationRuleDeletionIDs)
        for (id, revision) in result.newRevisionsByEventID {
            updated.knownEventRevisions[id] = revision
        }
        // A conflicted event stays in the outbox (still "pending") — the very next pull's
        // incremental cursor naturally picks up the newer remote write (its server-side commit
        // just advanced that row's own server_seq past this device's cursor), and
        // `downloadRemoteChanges` below runs it through the same conflict resolver as any other
        // two-sided change. No separate "re-fetch and resolve" path is needed.
        //
        // A permanent failure is not retried endlessly — dropped from the outbox after being
        // recorded (a transient failure simply leaves the id pending, retried on the next pass).
        for failed in result.failedEvents where failed.error.isPermanent {
            updated.pendingEventUploads.remove(failed.id)
        }
        for failed in result.failedExclusions where failed.error.isPermanent {
            updated.pendingExclusionUploads.remove(failed.id)
        }
        for failed in result.failedNotificationRuleDeletions where failed.error.isPermanent {
            updated.pendingNotificationRuleDeletions.remove(failed.id)
        }
        if let retryNotBefore = result.retryNotBefore {
            updated.retryNotBefore = retryNotBefore
        }
        stateStore.save(updated)

        // A hard transport-level rejection of the *whole* batch (never reached for per-record
        // failures, which already succeed at the HTTP level) would show up as every record
        // failing with a non-permanent, non-conflict error — treated as a pass failure only if
        // literally nothing succeeded and nothing was even attempted meaningfully.
        return true
    }

    // MARK: - Download (incremental, keyset-paginated)

    /// `.incomplete` is the Phase 5 correction this type exists for: reaching the per-pass page
    /// cap while the server still reported `hasMorePages == true` is neither success nor
    /// failure — it's bounded, expected progress (a large first sync, most commonly) that the
    /// next pass continues. Only `.failed` means the pass didn't complete due to an actual
    /// transport error.
    private enum PullOutcome: Equatable {
        case complete
        case incomplete
        case failed
    }

    private func downloadRemoteChanges(context: ModelContext, accessToken: String, now: Date) async -> PullOutcome {
        var state = stateStore.load()
        var cursor = state.pullCursor
        var pagesFetched = 0

        repeat {
            let page = await transport.pull(cursor: cursor, pageSize: Self.defaultPageSize, accessToken: accessToken)
            guard page.error == nil else { return .failed }

            do {
                try applyPage(page, context: context, state: &state, now: now)
            } catch {
                // The cursor must remain at the last page that was durably saved. Retrying the
                // same page is safe; advancing here would permanently skip remote events.
                context.rollback()
                return .failed
            }
            // Requirement H: "persisted cursor only after a page is safely applied" — the
            // context save inside `applyPage` already happened before this line runs.
            cursor = page.nextCursor
            state.pullCursor = cursor
            stateStore.save(state)
            pagesFetched += 1

            if !page.hasMorePages {
                if pagesFetched > 0 { await reconcileAfterPull(context: context, now: now) }
                return .complete
            }
        } while pagesFetched < Self.maxPagesPerPass

        // The cap was reached while the server still had more pages to send (Phase 5
        // correction — this used to fall through and report success unconditionally). Progress
        // already made is safely persisted above; the caller must not report `.upToDate`.
        if pagesFetched > 0 { await reconcileAfterPull(context: context, now: now) }
        return .incomplete
    }

    private func applyPage(_ page: SyncPullPage, context: ModelContext, state: inout SyncPersistentState, now: Date) throws {
        for record in page.changedEvents {
            let existing = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == record.id })))?.first
            let localState: SyncConflictResolver.LocalState
            if let existing {
                localState = .record(EventGraphMapper.record(for: existing))
            } else if let tombstoneDate = state.eventTombstones[record.id] {
                localState = .tombstone(deletedAt: tombstoneDate)
            } else {
                localState = .absent
            }

            switch localState {
            case .record(let localRecord) where localRecord.seriesID != nil && localRecord.seriesID == record.seriesID:
                // Requirement K: recurring-occurrence content/outcome split — never a plain
                // whole-graph winner-take-all here, so a legitimate offline completion/
                // cancellation/skip can't be silently discarded by a racing content edit.
                let merged = SyncConflictResolver.mergeRecurringOccurrence(local: localRecord, remote: record)
                applyWinningRecord(merged, existing: existing, context: context)
                state.eventTombstones.removeValue(forKey: record.id)
                state.knownEventRevisions[record.id] = record.revision
            default:
                switch SyncConflictResolver.resolve(local: localState, remote: .record(record)) {
                case .applyRemote(let winning):
                    applyWinningRecord(winning, existing: existing, context: context)
                    state.eventTombstones.removeValue(forKey: record.id)
                    state.knownEventRevisions[record.id] = record.revision
                case .restoreLocal(let localRecord):
                    state.pendingEventUploads.insert(localRecord.id)
                    state.knownEventRevisions[record.id] = record.revision
                case .deleteLocal, .keepLocal:
                    break // deleteLocal is only reachable from a tombstone entry below
                }
            }
        }

        for eventID in page.deletedEventIDs {
            let existing = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
            let localState: SyncConflictResolver.LocalState = existing.map { .record(EventGraphMapper.record(for: $0)) } ?? .absent
            switch SyncConflictResolver.resolve(local: localState, remote: .tombstone(deletedAt: now)) {
            case .deleteLocal:
                if let existing { context.delete(existing) }
                state.eventTombstones[eventID] = now
                state.knownEventRevisions.removeValue(forKey: eventID)
            case .restoreLocal(let localRecord):
                state.pendingEventUploads.insert(localRecord.id)
            default:
                break
            }
        }

        for record in page.changedExclusions {
            let existing = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == record.id })))?.first
            guard existing == nil else { continue } // exclusions are create-only, immutable once made
            context.insert(EventGraphMapper.makeExclusion(from: record))
        }

        try context.save()
    }

    private func applyWinningRecord(_ record: EventSyncRecord, existing: KueEvent?, context: ModelContext) {
        if let existing {
            let orphaned = EventGraphMapper.apply(record, to: existing)
            for task in orphaned.orphanedTasks { context.delete(task) }
            for rule in orphaned.orphanedNotificationRules { context.delete(rule) }
        } else {
            context.insert(EventGraphMapper.makeEvent(from: record))
        }
    }

    /// Requirement O: reconcile *once per batch*, not once per row, and — the exact regression
    /// this phase's own audit found — never rely solely on `EventReconciliation.run`'s own
    /// internal "did status/occurrences actually change" gate to decide whether to reload
    /// widgets/reindex Spotlight. A newly-downloaded event can have an already-correct derived
    /// status (so that gate sees no diff) while still being brand new to this device's widgets/
    /// Spotlight index — both are refreshed unconditionally here whenever this pull applied
    /// anything at all, never left to a narrower per-event heuristic.
    private func reconcileAfterPull(context: ModelContext, now: Date) async {
        await EventReconciliation.run(context: context, now: now)
        EventActions.reloadWidget()
        await SpotlightReconciliation.reindexAll(context: context, indexer: SystemSpotlightIndexer.shared, now: now)
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: SystemNotificationScheduler.shared, now: now)
    }

    // MARK: - First-sync decision (requirement J)

    /// Call only after `AccountFirstSyncDecisionView` has been shown and the user has made an
    /// explicit choice. Never called implicitly.
    func recordInitialSyncDecision(uploadExistingLocalData: Bool, context: ModelContext) {
        var state = stateStore.load()
        state.hasCompletedInitialSyncDecision = true
        stateStore.save(state)
        guard uploadExistingLocalData else { return }
        // Requirement J: "local-only + empty cloud: offer to upload existing local data" —
        // marks every existing local event/exclusion dirty so the very next sync pass pushes
        // the device's full current graph. Never touches anything if the user declined.
        if let events = try? context.fetch(FetchDescriptor<KueEvent>()) {
            for event in events { SyncOutbox.markEventDirty(event.id, store: stateStore) }
        }
        if let exclusions = try? context.fetch(FetchDescriptor<RecurrenceExclusion>()) {
            for exclusion in exclusions { SyncOutbox.markExclusionDirty(exclusion.id, store: stateStore) }
        }
    }

    /// Requirement J: "present clear choices based on actual state" — a read-only, single-page
    /// probe (never applies anything, never advances the real cursor) so
    /// `AccountFirstSyncDecisionView` can tell "cloud data exists for this account" apart from
    /// "empty cloud" before the user decides anything. `nil` means "couldn't determine"
    /// (offline/transport error) — the view falls back to its most conservative copy rather
    /// than guessing.
    func probeRemoteHasAnyData(account: AccountCoordinator) async -> Bool? {
        guard case .signedIn = account.state, let activeSession = await account.refreshIfNeeded() else { return nil }
        let page = await transport.pull(cursor: .initial, pageSize: 1, accessToken: activeSession.accessToken)
        guard page.error == nil else { return nil }
        return !page.changedEvents.isEmpty || !page.changedExclusions.isEmpty
    }

    /// "Not Now" — requirement J: sync stays off, local data is completely untouched, and the
    /// decision isn't re-asked unprompted on every launch (it's still reachable manually from
    /// Settings' own "Enable Sync" control).
    func deferInitialSyncDecision() {
        var state = stateStore.load()
        state.hasCompletedInitialSyncDecision = true
        stateStore.save(state)
        SyncPreference.setEnabled(false)
    }

    // MARK: - Sign-out / account switch (requirement L)

    /// Pauses sync, retains all local data, never deletes anything — the account id itself is
    /// left in `lastSyncedAccountID` so a later sign-*back*-in under the same account doesn't
    /// spuriously look like a switch.
    func pauseForSignOut() {
        status = .off
    }

    private func statusForTransportError(_ error: SyncTransportError, pendingCount: Int) -> SyncStatus {
        switch error {
        case .notAuthenticated, .sessionExpired: return .authenticationExpired
        case .networkUnavailable, .networkFailure: return .offline
        case .rateLimited(let seconds): return .retryScheduled(at: Date().addingTimeInterval(seconds))
        case .serviceUnavailable: return .offline
        case .conflict: return pendingCount > 0 ? .changesWaitingToUpload(count: pendingCount) : .upToDate
        case .quotaExceeded: return .syncError("Sync storage limit reached.")
        case .permissionFailure: return .syncError("Sync permission was denied.")
        case .corruptRecord, .unsupportedFutureRecordFormat, .validationFailed:
            return pendingCount > 0 ? .partialFailure(count: pendingCount) : .upToDate
        case .unknown(let message): return .syncError(message)
        }
    }

    /// Requirement Q: exponential backoff with jitter and a sensible cap, for a bare transient
    /// failure with no server-supplied `Retry-After` (a rate-limit response already sets its
    /// own `retryNotBefore` via `SyncPushResult`/`statusForTransportError` above).
    private func recordTransientFailureIfNeeded(_ error: SyncTransportError, now: Date) {
        guard !error.isPermanent else { return }
        var state = stateStore.load()
        state.consecutiveFailureCount += 1
        let base = 2.0, cap = 300.0
        let raw = min(cap, base * pow(2.0, Double(state.consecutiveFailureCount - 1)))
        let jitter = raw * Double.random(in: -0.2...0.2)
        state.retryNotBefore = now.addingTimeInterval(max(1, raw + jitter))
        stateStore.save(state)
    }
}
