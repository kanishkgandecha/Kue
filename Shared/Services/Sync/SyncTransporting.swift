//
//  SyncTransporting.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33-kue-3-supabase-cross-device-sync.md. The seam between
//  `SyncCoordinator` (Kue/Services/Sync/, orchestration) and the actual network transport.
//  Renamed from Kue 2.0 Phase 11's `CloudSyncTransporting` (docs/26) now that Supabase is
//  Kue's sole production sync backend (docs/33 "CloudKit retirement") — the shape below is the
//  same seam, extended for keyset pull pages and the notification-rule record type Phase 5
//  adds; `SupabaseSyncTransport` (Kue/Services/Sync/, app-only) is the one conforming type that
//  talks real HTTP, `FakeSyncTransport` below is the deterministic in-memory double every test
//  drives instead.
//

import Foundation

/// Every category of transport failure, as a closed, testable error surface — never a raw
/// `URLError`/HTTP status leaking past this file.
nonisolated enum SyncTransportError: Error, Equatable {
    case notAuthenticated
    case sessionExpired
    case networkUnavailable
    case networkFailure
    case serviceUnavailable
    case rateLimited(retryAfterSeconds: Double)
    case conflict
    case validationFailed
    case quotaExceeded
    case permissionFailure
    case corruptRecord
    case unsupportedFutureRecordFormat
    case unknown(String)

    /// A permanent failure is one no amount of retrying against the *same* state fixes without
    /// something else changing first (permission, quota, corruption, validation) — everything
    /// else is worth retrying on the next sync pass.
    var isPermanent: Bool {
        switch self {
        case .quotaExceeded, .permissionFailure, .corruptRecord, .unsupportedFutureRecordFormat, .validationFailed:
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

/// One event graph (event + tasks + schedule + notification rules), plus the two other
/// independently-pushed record kinds — see `EventSyncRecord`'s own header for why these travel
/// together rather than as separate cursors.
nonisolated struct SyncPushBatch: Equatable {
    var eventSaves: [EventSyncRecord] = []
    var eventDeletions: [UUID] = []
    var exclusionSaves: [RecurrenceExclusionSyncRecord] = []
    var notificationRuleDeletions: [UUID] = []

    var isEmpty: Bool {
        eventSaves.isEmpty && eventDeletions.isEmpty && exclusionSaves.isEmpty && notificationRuleDeletions.isEmpty
    }
}

nonisolated struct SyncPushResult: Equatable {
    var succeededEventIDs: Set<UUID> = []
    var succeededEventDeletionIDs: Set<UUID> = []
    var succeededExclusionIDs: Set<UUID> = []
    var succeededNotificationRuleDeletionIDs: Set<UUID> = []
    var failedEvents: [SyncFailedItem] = []
    var failedExclusions: [SyncFailedItem] = []
    /// Phase 5 correction (requirement G/4): populated from the RPC's own per-item results,
    /// never inferred from a batch-wide HTTP status — a 2xx response only means the *call*
    /// succeeded, not that every rule id in it was actually deleted.
    var failedNotificationRuleDeletions: [SyncFailedItem] = []
    /// Requirement G: "per-record conflict results" — an event graph whose push was rejected
    /// because the server's revision had already moved on (someone else's newer write landed
    /// first) is neither "succeeded" nor a hard failure; the coordinator re-fetches it on the
    /// next pull and runs `SyncConflictResolver` before ever retrying the push.
    var conflictedEventIDs: Set<UUID> = []
    /// The server-assigned revision for each successfully-pushed event — persisted as the new
    /// "expected revision" for that id's *next* push (optimistic concurrency).
    var newRevisionsByEventID: [UUID: Int64] = [:]
    /// Set only on a rate-limit response — `SyncCoordinator` persists this and skips further
    /// sends until it passes.
    var retryNotBefore: Date?
}

/// A server-controlled, monotonically-ordered position per record kind — requirement H:
/// "server-controlled monotonically ordered cursor... stable tie-breaking... no offset
/// pagination." One `Int64` per kind is sufficient tie-breaking on its own (each is drawn from
/// one shared Postgres sequence, `kue_sync_seq` — see the Phase 5 migration — so no two rows
/// across any of these tables can ever share a value).
nonisolated struct SyncCursor: Codable, Equatable {
    var events: Int64 = 0
    var exclusions: Int64 = 0

    static let initial = SyncCursor()
}

nonisolated struct SyncPullPage: Equatable {
    var changedEvents: [EventSyncRecord] = []
    var deletedEventIDs: [UUID] = []
    var changedExclusions: [RecurrenceExclusionSyncRecord] = []
    /// A downloaded record whose stamped format version this build can't decode, or that
    /// otherwise failed to parse — quarantined (id known where recoverable, content never
    /// applied), never crashed on or guessed at.
    var quarantinedEventIDs: [UUID] = []
    var nextCursor: SyncCursor
    /// True when this page was exactly `pageSize` rows for at least one kind — the caller must
    /// request another page before considering the graph fully reconstructed (requirement H:
    /// "a newly signed-in device must eventually reconstruct the complete synchronized graph
    /// through repeated pages").
    var hasMorePages: Bool = false
    var error: SyncTransportError?
}

/// Kue 3.0 Phase 5 — installed when Supabase configuration is absent or the account is
/// signed out: never constructs a real request, fails closed on every operation. Mirrors
/// `NullCloudSyncTransport`'s own Kue 2.0 Phase 12 role exactly, generalized past CloudKit.
struct NullSyncTransport: SyncTransporting {
    func ensureReady(accessToken: String) async -> Result<Void, SyncTransportError> { .failure(.notAuthenticated) }
    func push(_ batch: SyncPushBatch, accessToken: String) async -> SyncPushResult { SyncPushResult() }
    func pull(cursor: SyncCursor, pageSize: Int, accessToken: String) async -> SyncPullPage { SyncPullPage(nextCursor: cursor, error: .notAuthenticated) }
    func resetLocalAccountState() async {}
}

nonisolated protocol SyncTransporting: Sendable {
    /// Idempotent — safe to call at the start of every sync pass. A lightweight readiness/auth
    /// check, not a CloudKit-style "ensure zone exists" (Postgres tables always exist once the
    /// migration is applied; what can fail here is authentication/network only).
    func ensureReady(accessToken: String) async -> Result<Void, SyncTransportError>

    /// `accessToken` is always a *freshly refreshed-if-needed* token, obtained by the caller
    /// (`SyncCoordinator`) through `AccountCoordinator.refreshIfNeeded()` — this transport
    /// never owns a session or talks to `AccountCoordinator` itself, the same "receive a
    /// session, never fetch one" shape `SystemAccountProvider`'s own authenticated calls
    /// already establish (requirement M: "avoid duplicated refresh logic").
    func push(_ batch: SyncPushBatch, accessToken: String) async -> SyncPushResult

    /// One page, starting strictly after `cursor` — never an offset. `pageSize` bounds both the
    /// request and, on the client side, memory (requirement U: "memory is bounded by page/batch
    /// size rather than the total account dataset").
    func pull(cursor: SyncCursor, pageSize: Int, accessToken: String) async -> SyncPullPage

    /// Quarantines/discards this device's queued-but-unsent state for the *previous* account —
    /// called before ever pushing under a newly signed-in account, so no record produced under
    /// Account A can ever be uploaded into Account B's rows.
    func resetLocalAccountState() async
}
