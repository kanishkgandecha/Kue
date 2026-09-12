//
//  StatisticsTransporting.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Transport and synchronization." A deliberately narrow seam:
//  exactly the three operations cloud statistics ever needs (requirement E: "a protocol
//  containing only aggregate upload/download/delete operations") — never mixed into
//  `SyncTransporting`'s own event-graph push/pull cursor state (requirement E: "do not mix
//  aggregate-statistics cursors or state into the event graph synchronization protocol").
//  Reuses `SyncTransportError` (Shared/Services/Sync/SyncTransporting.swift) rather than a
//  second, near-identical error enum — every case there (network/auth/rate-limit/permission/
//  validation/service-unavailable/...) already means exactly the same thing for this transport.
//
//  `SupabaseStatisticsTransport` (the one conforming type that talks real HTTP) never owns or
//  refreshes a session itself, same "receive an already-valid accessToken" contract
//  `SupabaseSyncTransport` already establishes (requirement E: "refresh sessions through the
//  existing AccountCoordinator path").
//

import Foundation

nonisolated protocol StatisticsTransporting: Sendable {
    /// Idempotent — a PostgREST upsert against `statistics_aggregates`' own
    /// `(user_id, bucket_start)` primary key, never a second row per week (requirement D:
    /// "idempotent upsert behavior").
    func upload(_ payload: StatisticsAggregatePayload, accessToken: String) async -> Result<Void, SyncTransportError>

    /// This account's own previously-uploaded weekly rows, most recent first — used only to
    /// let the UI show how many weeks of cloud history exist across this account's devices;
    /// never merged into the local weekly-activity chart (requirement E's own transport is
    /// narrow; the merge logic requirement C didn't ask for is deliberately not built).
    func fetchRecentAggregates(accessToken: String, userID: UUID) async -> Result<[StatisticsAggregatePayload], SyncTransportError>

    /// Requirement F: "Delete Cloud Statistics" — every one of this account's own aggregate
    /// rows, permanently. Never touches the account itself or any local event/task.
    func deleteAll(accessToken: String, userID: UUID) async -> Result<Void, SyncTransportError>
}

/// Installed when Supabase configuration is absent or the account is signed out — mirrors
/// `NullSyncTransport`'s own role exactly: fails closed on every operation, never constructs a
/// real request.
struct NullStatisticsTransport: StatisticsTransporting {
    func upload(_ payload: StatisticsAggregatePayload, accessToken: String) async -> Result<Void, SyncTransportError> { .failure(.notAuthenticated) }
    func fetchRecentAggregates(accessToken: String, userID: UUID) async -> Result<[StatisticsAggregatePayload], SyncTransportError> { .failure(.notAuthenticated) }
    func deleteAll(accessToken: String, userID: UUID) async -> Result<Void, SyncTransportError> { .failure(.notAuthenticated) }
}
