//
//  SyncCoordinator.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "B./M." The one orchestrator that owns
//  CloudKit synchronization — app-only (docs/26 "B.": "Only the main Kue app process owns
//  CloudKit synchronization"). `@MainActor` implicitly (this module's own
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, same as `LiveActivityFocusCoordinator`/every
//  other app-owned coordinator) — every `ModelContext` this touches is the app's own
//  `container.mainContext`, never crossed to a background actor (docs/26 "M.": "Never pass
//  `ModelContext` across actors unsafely").
//
//  Every step below is built from already-existing, already-tested pieces — this file adds no
//  new business rule, only sequencing: `EventGraphMapper` (encode/decode), `SyncConflictResolver`
//  (pure decision), `EventReconciliation.run` (status/occurrence/widget/Spotlight/Live-Activity,
//  Kue 2.0 Phase 3–10), `NotificationEngine.reschedule` (Phase 8/10.1).
//

import Foundation
import SwiftData
import Observation

/// `@Observable` — `SyncSettingsSection`/Home's restrained banner read `.status` directly and
/// need SwiftUI to re-render when it changes after a `sync(context:)` call.
@MainActor
@Observable
final class SyncCoordinator {
    /// A `var`, not `let` — `KueApp` swaps this for a fake-backed instance under
    /// `KueUITests` (docs/26 "R.": "Do not require a real iCloud account for unit or UI
    /// tests"), the same "install a fake behind the one production singleton" pattern
    /// `FakeLiveActivityManager.makeFromLaunchArguments`/`FakeSpotlightIndexer` already
    /// establish, adapted here since `SyncCoordinator` is read from call sites (`HomeView`,
    /// `SettingsView`) directly rather than through a SwiftUI `\.environment` seam.
    static var shared = SyncCoordinator()

    /// Exposed (not `private`) so `SettingsView`'s pending-count/last-sync display reads
    /// through the *same* store this coordinator itself uses — under `KueUITests`, that's the
    /// fake in-memory store `makeFromLaunchArguments()` installs, never the real
    /// `SystemCloudSyncStateStore.shared` file (which persists across every process launch on
    /// a real device/simulator install and must never leak real accumulated state into a
    /// UI test's supposedly-isolated view).
    let stateStore: CloudSyncStatePersisting
    private let transport: CloudSyncTransporting
    private let accountProvider: CloudAccountProviding
    private let clock: SyncClock

    private(set) var status: SyncStatus = .off
    private var isSyncing = false

    init(
        stateStore: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared,
        transport: CloudSyncTransporting = SyncCoordinator.defaultTransport,
        accountProvider: CloudAccountProviding = SyncCoordinator.defaultAccountProvider,
        clock: SyncClock = SystemSyncClock()
    ) {
        self.stateStore = stateStore
        self.transport = transport
        self.accountProvider = accountProvider
        self.clock = clock
    }

    /// Kue 2.0 Phase 12 — docs/27: the structural half of Personal-build CloudKit exclusion.
    /// `KuePersonal.entitlements` already omits the CloudKit keys (so any real CloudKit call
    /// would fail at the OS level), but the spec requires more than that: no `CKContainer`/
    /// `CKDatabase`/`CKSyncEngine` may even be *instantiated* in this build. `SystemCloudSyncTransport.shared`
    /// and `SystemCloudAccountProvider()` each construct a `CKContainer` the moment they're
    /// evaluated as a default-parameter value — so the swap has to happen here, at the type
    /// chosen for the default, not inside `sync(context:)`.
    nonisolated private static var defaultTransport: CloudSyncTransporting {
        #if KUE_PERSONAL_BUILD
        NullCloudSyncTransport()
        #else
        SystemCloudSyncTransport.shared
        #endif
    }

    nonisolated private static var defaultAccountProvider: CloudAccountProviding {
        #if KUE_PERSONAL_BUILD
        NullCloudAccountProvider()
        #else
        SystemCloudAccountProvider()
        #endif
    }

    /// Must match `UITestLaunchConfiguration.fakeSyncArgument` (KueUITests/) exactly — same
    /// "shared literal, same rationale" every other fake-service launch argument in this
    /// codebase already establishes. Installed once, at `KueApp.init()`, replacing `.shared`
    /// wholesale (not individual dependencies) so every call site (`HomeView`, `SettingsView`)
    /// automatically gets the fake-backed instance with no seam of its own to thread through.
    static let uiTestLaunchArgument = "-uiTestFakeSync"

    /// `nil` when `uiTestLaunchArgument` isn't present — `KueApp` falls back to the real,
    /// system-backed default `SyncCoordinator()` in that case. The fakes are pre-seeded with
    /// an available account and enabled preference so a UI test can drive the sync UI states
    /// deterministically without ever touching a real account.
    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SyncCoordinator? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        SyncPreference.setEnabled(true)
        return SyncCoordinator(
            stateStore: FakeCloudSyncStateStore(),
            transport: FakeCloudSyncTransport(),
            accountProvider: FakeCloudAccountProvider(),
            clock: SystemSyncClock()
        )
    }

    /// The one entry point every trigger (docs/26 "M.": launch, scene activation, remote
    /// notification, manual Sync Now, outbox change, network/account recovery) calls.
    /// Reentrancy-safe — a call that arrives while one is already running is a no-op, not a
    /// second concurrent pass (`CKSyncEngine` itself already coalesces its own scheduling;
    /// this guard is for the surrounding local-apply/reconciliation work this file adds).
    @discardableResult
    func sync(context: ModelContext, now: Date? = nil) async -> SyncStatus {
        let now = now ?? clock.now
        guard SyncPreference.current.isEnabled else {
            status = .off
            return status
        }
        guard !isSyncing else { return status }
        isSyncing = true
        defer { isSyncing = false }

        status = .checkingAccount
        let accountState = await accountProvider.currentState()
        switch accountState {
        case .noAccount:
            status = .waitingForSignIn
            return status
        case .restricted:
            status = .waitingForSignIn
            return status
        case .temporarilyUnavailable, .couldNotDetermine:
            status = .temporarilyUnavailable
            return status
        case .available:
            break
        }

        // docs/26 "G.": an account switch must never let the previous account's pending
        // records reach the new account, and must never silently merge — surfaced as a
        // blocking status until `resolveAccountChange(keepingCloudData:)` is called explicitly.
        var state = stateStore.load()
        let currentFingerprint = await accountProvider.currentAccountFingerprint()
        if let stored = state.accountFingerprint, let current = currentFingerprint, stored != current {
            status = .accountChanged
            return status
        }
        if state.accountFingerprint == nil, let current = currentFingerprint {
            state.accountFingerprint = current
            stateStore.save(state)
        }

        if let retryNotBefore = state.retryNotBefore, retryNotBefore > now {
            status = .waitingForNetwork
            return status
        }

        status = .syncing

        if case .failure(let error) = await transport.ensureZoneExists() {
            status = statusForTransportError(error, pendingCount: SyncOutbox.pendingChangeCount(store: stateStore))
            return status
        }

        await uploadPendingChanges(context: context, now: now)
        await applyRemoteChanges(context: context, now: now)

        state = stateStore.load()
        state.lastSuccessfulSyncAt = now
        stateStore.save(state)
        SyncOutbox.pruneExpiredTombstones(now: now, store: stateStore)

        let pending = SyncOutbox.pendingChangeCount(store: stateStore)
        status = pending > 0 ? .changesWaitingToUpload(count: pending) : .upToDate
        return status
    }

    // MARK: - Upload

    private func uploadPendingChanges(context: ModelContext, now: Date) async {
        let state = stateStore.load()
        guard !state.pendingEventUploads.isEmpty || !state.pendingEventDeletions.isEmpty
            || !state.pendingExclusionUploads.isEmpty || !state.pendingExclusionDeletions.isEmpty else { return }

        let eventSaves: [EventSyncRecord] = state.pendingEventUploads.compactMap { id in
            guard let event = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })))?.first else { return nil }
            return EventGraphMapper.record(for: event)
        }
        let exclusionSaves: [RecurrenceExclusionSyncRecord] = state.pendingExclusionUploads.compactMap { id in
            guard let exclusion = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == id })))?.first else { return nil }
            return EventGraphMapper.record(for: exclusion)
        }

        let result = await transport.send(
            eventSaves: eventSaves,
            eventDeletions: Array(state.pendingEventDeletions),
            exclusionSaves: exclusionSaves,
            exclusionDeletions: Array(state.pendingExclusionDeletions)
        )

        var updated = stateStore.load()
        updated.pendingEventUploads.subtract(result.succeededEventIDs)
        updated.pendingEventDeletions.subtract(result.succeededEventDeletionIDs)
        updated.pendingExclusionUploads.subtract(result.succeededExclusionIDs)
        updated.pendingExclusionDeletions.subtract(result.succeededExclusionDeletionIDs)
        // docs/26 "N.": permanent failures are not retried endlessly — dropped from the
        // outbox after being recorded as failed (a transient failure simply leaves the id
        // pending, retried on the next sync pass with no special handling needed).
        for failed in result.failedEvents where failed.error.isPermanent {
            updated.pendingEventUploads.remove(failed.id)
        }
        for failed in result.failedExclusions where failed.error.isPermanent {
            updated.pendingExclusionUploads.remove(failed.id)
        }
        if let retryNotBefore = result.retryNotBefore {
            updated.retryNotBefore = retryNotBefore
        }
        stateStore.save(updated)
    }

    // MARK: - Apply remote changes

    private func applyRemoteChanges(context: ModelContext, now: Date) async {
        let fetch = await transport.fetchChanges()
        guard fetch.error == nil else { return }

        var changedAnything = false
        var state = stateStore.load()

        for record in fetch.changedEvents {
            let existing = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == record.id })))?.first
            let localState: SyncConflictResolver.LocalState
            if let existing {
                localState = .record(EventGraphMapper.record(for: existing))
            } else if let tombstoneDate = state.eventTombstones[record.id] {
                localState = .tombstone(deletedAt: tombstoneDate)
            } else {
                localState = .absent
            }
            switch SyncConflictResolver.resolve(local: localState, remote: .record(record)) {
            case .applyRemote(let winning):
                if let existing {
                    let orphaned = EventGraphMapper.apply(winning, to: existing)
                    for task in orphaned { context.delete(task) }
                } else {
                    context.insert(EventGraphMapper.makeEvent(from: winning))
                }
                state.eventTombstones.removeValue(forKey: record.id)
                changedAnything = true
            case .restoreLocal(let localRecord):
                // The local record is newer than what CloudKit currently reflects — queue it
                // for re-upload rather than mutate anything locally.
                state.pendingEventUploads.insert(localRecord.id)
            case .deleteLocal, .keepLocal:
                break // deleteLocal only reachable when local exists as a live record, not from a `.changedEvents` entry
            }
        }

        for eventID in fetch.deletedEventIDs {
            let existing = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first
            let localState: SyncConflictResolver.LocalState = existing.map { .record(EventGraphMapper.record(for: $0)) } ?? .absent
            switch SyncConflictResolver.resolve(local: localState, remote: .tombstone(deletedAt: now)) {
            case .deleteLocal:
                if let existing { context.delete(existing) }
                state.eventTombstones[eventID] = now
                changedAnything = true
            case .restoreLocal(let localRecord):
                state.pendingEventUploads.insert(localRecord.id)
            default:
                break
            }
        }

        for record in fetch.changedExclusions {
            let existing = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == record.id })))?.first
            guard existing == nil else { continue } // exclusions are create-only, immutable once made
            context.insert(EventGraphMapper.makeExclusion(from: record))
            changedAnything = true
        }
        for exclusionID in fetch.deletedExclusionIDs {
            if let existing = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == exclusionID })))?.first {
                context.delete(existing)
                changedAnything = true
            }
        }

        try? context.save()
        stateStore.save(state)

        if changedAnything {
            // docs/26 "B./Q.": the exact same bounded reconciliation pipeline every other
            // mutation surface already triggers — status/occurrence horizon/widget reload/
            // Spotlight/focused-Live-Activity, all reused, none re-derived here.
            await EventReconciliation.run(context: context, now: now)
            let intensity = UserPreferenceStore.current(context: context).notificationIntensity
            await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: SystemNotificationScheduler.shared, now: now)
        }
    }

    // MARK: - Account change resolution (docs/26 "G.")

    /// Call only after the user has been shown the app-owned decision explaining that local
    /// Kue data currently belongs to another iCloud sync context, and has explicitly chosen.
    /// `keepLocalAndStartFresh: true` quarantines the previous account's pending/engine state
    /// (never uploads it into the new account) and treats the new account as a fresh initial
    /// sync target for this device's current local data — the safe default. Nothing here ever
    /// deletes local data.
    func resolveAccountChange(keepLocalAndStartFresh: Bool) async {
        guard keepLocalAndStartFresh else { return }
        await transport.resetEngineState()
        var state = stateStore.load()
        state.engineStateData = nil
        state.accountFingerprint = await accountProvider.currentAccountFingerprint()
        // Every locally-known event becomes "needs upload" again under the new account —
        // the previous account's own CloudKit copy is left untouched (docs/26 primary
        // guarantee: disabling/switching never deletes CloudKit content).
        state.eventTombstones = [:]
        state.exclusionTombstones = [:]
        stateStore.save(state)
    }

    // MARK: - Sign-out (docs/26 "G.")

    /// Pauses sync, retains all local data, never deletes anything — the account fingerprint
    /// itself is left in place so a later sign-*back*-in under the same account doesn't
    /// spuriously look like an account change.
    func pauseForSignOut() {
        status = .paused
    }

    private func statusForTransportError(_ error: SyncTransportError, pendingCount: Int) -> SyncStatus {
        switch error {
        case .notAuthenticated: return .waitingForSignIn
        case .accountTemporarilyUnavailable, .serviceUnavailable, .zoneBusy: return .temporarilyUnavailable
        case .networkUnavailable, .networkFailure: return .waitingForNetwork
        case .rateLimited: return .waitingForNetwork
        case .zoneNotFound, .changeTokenExpired: return .syncError("Sync needs to restart — this resolves automatically.")
        case .quotaExceeded: return .syncError("iCloud storage is full.")
        case .permissionFailure: return .syncError("iCloud permission was denied.")
        case .corruptRecord, .unsupportedFutureRecordFormat, .unknownItem, .serverRecordChanged:
            return pendingCount > 0 ? .changesWaitingToUpload(count: pendingCount) : .upToDate
        case .unknown(let message): return .syncError(message)
        }
    }
}
