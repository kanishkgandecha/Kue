//
//  FakeStatisticsTransport.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Testing." Deterministic in-memory double — no real network, no
//  real account, ever. Used by `KueTests`/`KueUITests`/`KueMacTests` only.
//
//  Keyed by `accessToken`, not by an account id `SyncCoordinator`-style — this fake stands in
//  for what real RLS enforces server-side (a row is only ever visible/writable under its own
//  account's token), which makes "does the transport ever leak Account A's data under Account
//  B's token" a directly testable property here, not something only a real Postgres constraint
//  could prove (contrast Phase 5's own `FakeSyncTransport`, which stayed a single flat table —
//  disclosed there as a SQL-only proof — because that transport's real account-isolation
//  guarantee comes from a composite *primary key*, not a lookup a plain dictionary can mirror
//  faithfully; a per-user upsert table has no such subtlety).
//
//  `@unchecked Sendable` — internally serialized by `lock`, same shape `FakeSyncTransport`
//  already uses.
//

import Foundation

final class FakeStatisticsTransport: StatisticsTransporting, @unchecked Sendable {
    private let lock = NSLock()
    /// accessToken → bucketStart → payload, exactly mirroring the real table's own
    /// `(user_id, bucket_start)` primary key (accessToken standing in for the account a real
    /// server would resolve from it via `auth.uid()`).
    private var rowsByToken: [String: [String: StatisticsAggregatePayload]] = [:]

    var uploadCallCount = 0
    var deleteCallCount = 0
    var nextUploadError: SyncTransportError?
    var nextFetchError: SyncTransportError?
    var nextDeleteError: SyncTransportError?

    func upload(_ payload: StatisticsAggregatePayload, accessToken: String) async -> Result<Void, SyncTransportError> {
        lock.lock(); defer { lock.unlock() }
        uploadCallCount += 1
        if let error = nextUploadError { nextUploadError = nil; return .failure(error) }
        rowsByToken[accessToken, default: [:]][payload.bucketStart] = payload
        return .success(())
    }

    func fetchRecentAggregates(accessToken: String, userID: UUID) async -> Result<[StatisticsAggregatePayload], SyncTransportError> {
        lock.lock(); defer { lock.unlock() }
        if let error = nextFetchError { nextFetchError = nil; return .failure(error) }
        let rows = (rowsByToken[accessToken] ?? [:]).values.sorted { $0.bucketStart > $1.bucketStart }
        return .success(rows)
    }

    func deleteAll(accessToken: String, userID: UUID) async -> Result<Void, SyncTransportError> {
        lock.lock(); defer { lock.unlock() }
        deleteCallCount += 1
        if let error = nextDeleteError { nextDeleteError = nil; return .failure(error) }
        rowsByToken[accessToken] = [:]
        return .success(())
    }

    // MARK: - Test inspection

    func storedPayloads(forToken accessToken: String) -> [StatisticsAggregatePayload] {
        lock.lock(); defer { lock.unlock() }
        return Array((rowsByToken[accessToken] ?? [:]).values)
    }
}
