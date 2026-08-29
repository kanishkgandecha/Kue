//
//  CloudSyncTransporting.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "N./R." The one seam between `SyncCoordinator` (Kue/Services/
//  Sync/, orchestration) and the actual network/CloudKit transport. `SystemCloudSyncTransport`
//  (app-only) is the only conforming type that imports CloudKit/wraps a real `CKSyncEngine`;
//  `FakeCloudSyncTransport` below is a deterministic in-memory "CloudKit" good enough to drive
//  every offline/conflict/error scenario in docs/26 "S." without a real account or network.
//

import Foundation

/// docs/26 "N." — every category that section names, as a closed, testable error surface
/// rather than a raw `CKError` leaking past this file.
nonisolated enum SyncTransportError: Error, Equatable {
    case notAuthenticated
    case accountTemporarilyUnavailable
    case networkUnavailable
    case networkFailure
    case serviceUnavailable
    case rateLimited(retryAfterSeconds: Double)
    case zoneBusy
    case serverRecordChanged
    case quotaExceeded
    case permissionFailure
    case unknownItem
    case zoneNotFound
    case changeTokenExpired
    case corruptRecord
    case unsupportedFutureRecordFormat
    case unknown(String)

    /// docs/26 "N.": "Do not retry permanent failures endlessly." A permanent failure is one
    /// no amount of retrying against the *same* state fixes without something else changing
    /// first (permission, quota, corruption) — everything else is worth retrying.
    var isPermanent: Bool {
        switch self {
        case .quotaExceeded, .permissionFailure, .corruptRecord, .unsupportedFutureRecordFormat, .unknownItem:
            return true
        default:
            return false
        }
    }
}

nonisolated struct SyncFailedItem: Equatable {
    var id: UUID
    var error: SyncTransportError
}

nonisolated struct SyncSendResult: Equatable {
    var succeededEventIDs: Set<UUID> = []
    var succeededEventDeletionIDs: Set<UUID> = []
    var succeededExclusionIDs: Set<UUID> = []
    var succeededExclusionDeletionIDs: Set<UUID> = []
    var failedEvents: [SyncFailedItem] = []
    var failedExclusions: [SyncFailedItem] = []
    /// Set only on a rate-limit response — `SyncCoordinator` persists this as
    /// `SyncPersistentState.retryNotBefore` and skips further sends until it passes.
    var retryNotBefore: Date?
}

nonisolated struct SyncFetchResult: Equatable {
    var changedEvents: [EventSyncRecord] = []
    var deletedEventIDs: [UUID] = []
    var changedExclusions: [RecurrenceExclusionSyncRecord] = []
    var deletedExclusionIDs: [UUID] = []
    /// docs/26 "O.": a downloaded record whose stamped format version this build can't
    /// decode — quarantined (id known, content never applied), not crashed on or guessed at.
    var quarantinedEventIDs: [UUID] = []
    var quarantinedExclusionIDs: [UUID] = []
    var error: SyncTransportError?
}

/// Kue 2.0 Phase 12 — docs/27. The transport `SyncCoordinator` installs under
/// `KUE_PERSONAL_BUILD` in place of `SystemCloudSyncTransport`: never constructs a
/// `CKContainer`/`CKDatabase`/`CKSyncEngine` — there is nothing here that imports CloudKit.
/// `SyncCoordinator` forces `SyncPreference.isEnabled` to `false` in this build, so none of
/// these methods are ever actually reached; every one fails closed (reports "not
/// authenticated") on the off chance something calls in directly.
struct NullCloudSyncTransport: CloudSyncTransporting {
    func ensureZoneExists() async -> Result<Void, SyncTransportError> { .failure(.notAuthenticated) }
    func send(
        eventSaves: [EventSyncRecord],
        eventDeletions: [UUID],
        exclusionSaves: [RecurrenceExclusionSyncRecord],
        exclusionDeletions: [UUID]
    ) async -> SyncSendResult { SyncSendResult() }
    func fetchChanges() async -> SyncFetchResult { SyncFetchResult(error: .notAuthenticated) }
    func resetEngineState() async {}
}

nonisolated protocol CloudSyncTransporting: Sendable {
    /// Idempotent — safe to call every launch. docs/26 "N.": zone-not-found/zone-busy are
    /// real possible outcomes here, not just at send/fetch time.
    func ensureZoneExists() async -> Result<Void, SyncTransportError>

    func send(
        eventSaves: [EventSyncRecord],
        eventDeletions: [UUID],
        exclusionSaves: [RecurrenceExclusionSyncRecord],
        exclusionDeletions: [UUID]
    ) async -> SyncSendResult

    func fetchChanges() async -> SyncFetchResult

    /// docs/26 "G.": quarantines/discards this device's queued-but-unsent CloudKit-side state
    /// for the *previous* account — called before ever sending under a newly signed-in
    /// account, so no record produced under Apple ID A can ever be uploaded into Apple ID B's
    /// private database.
    func resetEngineState() async
}
