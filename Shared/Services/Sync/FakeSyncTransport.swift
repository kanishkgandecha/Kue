//
//  FakeSyncTransport.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Testing." Deterministic in-memory "Supabase" — a `Dictionary`
//  standing in for the remote tables, plus test-controlled error/latency injection. No real
//  network, no real account, ever. Used by `KueTests`/`KueUITests` and nowhere else. Renamed/
//  extended from Kue 2.0 Phase 11's `FakeCloudSyncTransport` (docs/26 "R./S.") — same shape,
//  keyset-cursor pull instead of a single unpaginated fetch, revision-based optimistic
//  concurrency instead of a bare success/fail.
//
//  `@unchecked Sendable` — internally serialized by `lock`, same shape
//  `FakeLiveActivityManager`/`FakeSpotlightIndexer` already use for their own test doubles.
//

import Foundation

final class FakeSyncTransport: SyncTransporting, @unchecked Sendable {
    private let lock = NSLock()

    /// The "server's" own table — every successfully-pushed or seeded-as-remote event, keyed
    /// by id, in ascending `server_seq` order of last write (index into this array position
    /// order is itself the cursor position).
    private(set) var eventsInSeqOrder: [EventSyncRecord] = []
    private(set) var deletedEventIDs: Set<UUID> = []
    private(set) var exclusionsInSeqOrder: [RecurrenceExclusionSyncRecord] = []
    private(set) var deletedNotificationRuleIDs: Set<UUID> = []
    /// Client mutation ids already applied — a retried push carrying one of these is
    /// recognized and no-op'd, exactly like the real RPC's own idempotent upsert.
    private(set) var appliedMutationIDs: Set<UUID> = []

    /// Test-injected outcomes — set before calling into `SyncCoordinator`, consumed (and
    /// cleared, single-shot) by the next matching call, so a test can simulate "fails once,
    /// then succeeds on retry" without hand-rolling a state machine per case.
    var nextEnsureReadyError: SyncTransportError?
    var nextPushError: SyncTransportError?
    var nextPullError: SyncTransportError?
    /// Simulates a remote record already stamped with a future format version this "build"
    /// can't decode — surfaced as a quarantined id, never applied.
    var futureVersionEventIDs: Set<UUID> = []
    /// Simulates the server rejecting a specific event id's push as a revision conflict
    /// (someone else's newer write already landed) — single-shot, like the errors above.
    var conflictEventIDs: Set<UUID> = []
    /// Simulates `push_recurrence_exclusions`/`push_notification_rule_deletions` reporting a
    /// per-item permanent failure for just this one id while the rest of the batch still
    /// succeeds — Phase 5 correction (requirement G/4): a real per-item result, not an
    /// all-or-nothing batch outcome. Single-shot, consumed on the next `push(_:)` that contains it.
    var permanentlyFailingExclusionIDs: Set<UUID> = []
    var permanentlyFailingNotificationRuleDeletionIDs: Set<UUID> = []

    var ensureReadyCallCount = 0
    var lastEnsureReadyAccessToken: String?
    var pushCallCount = 0
    var pullCallCount = 0
    var resetCallCount = 0

    func ensureReady(accessToken: String) async -> Result<Void, SyncTransportError> {
        lock.withLock {
            ensureReadyCallCount += 1
            lastEnsureReadyAccessToken = accessToken
            if let error = nextEnsureReadyError {
                nextEnsureReadyError = nil
                return .failure(error)
            }
            return .success(())
        }
    }

    func push(_ batch: SyncPushBatch, accessToken: String) async -> SyncPushResult {
        lock.withLock {
            pushCallCount += 1
            if let error = nextPushError {
                nextPushError = nil
                if case .rateLimited(let seconds) = error {
                    return SyncPushResult(retryNotBefore: Date().addingTimeInterval(seconds))
                }
                let failedEvents = batch.eventSaves.map { SyncFailedItem(id: $0.id, error: error) }
                return SyncPushResult(failedEvents: failedEvents)
            }

            var result = SyncPushResult()
            for record in batch.eventSaves {
                if conflictEventIDs.contains(record.id) {
                    conflictEventIDs.remove(record.id)
                    result.conflictedEventIDs.insert(record.id)
                    continue
                }
                if appliedMutationIDs.contains(record.clientMutationID) {
                    // Idempotent retry — already applied, report success without re-applying.
                    result.succeededEventIDs.insert(record.id)
                    if let existingRevision = eventsInSeqOrder.first(where: { $0.id == record.id })?.revision {
                        result.newRevisionsByEventID[record.id] = existingRevision
                    }
                    continue
                }
                var stamped = record
                let newRevision = (eventsInSeqOrder.first(where: { $0.id == record.id })?.revision ?? 0) + 1
                stamped.revision = newRevision
                stamped.updatedAt = Date() // simulates the server's own server_updated_at stamp
                eventsInSeqOrder.removeAll { $0.id == record.id }
                eventsInSeqOrder.append(stamped)
                deletedEventIDs.remove(record.id)
                appliedMutationIDs.insert(record.clientMutationID)
                result.succeededEventIDs.insert(record.id)
                result.newRevisionsByEventID[record.id] = newRevision
            }
            for id in batch.eventDeletions {
                eventsInSeqOrder.removeAll { $0.id == id }
                deletedEventIDs.insert(id)
                result.succeededEventDeletionIDs.insert(id)
            }
            for record in batch.exclusionSaves {
                if permanentlyFailingExclusionIDs.remove(record.id) != nil {
                    result.failedExclusions.append(SyncFailedItem(id: record.id, error: .validationFailed))
                    continue
                }
                if !appliedMutationIDs.contains(record.clientMutationID) {
                    exclusionsInSeqOrder.append(record)
                    appliedMutationIDs.insert(record.clientMutationID)
                }
                result.succeededExclusionIDs.insert(record.id)
            }
            for id in batch.notificationRuleDeletions {
                if permanentlyFailingNotificationRuleDeletionIDs.remove(id) != nil {
                    result.failedNotificationRuleDeletions.append(SyncFailedItem(id: id, error: .validationFailed))
                    continue
                }
                deletedNotificationRuleIDs.insert(id)
                result.succeededNotificationRuleDeletionIDs.insert(id)
            }
            return result
        }
    }

    func pull(cursor: SyncCursor, pageSize: Int, accessToken: String) async -> SyncPullPage {
        lock.withLock {
            pullCallCount += 1
            if let error = nextPullError {
                nextPullError = nil
                return SyncPullPage(nextCursor: cursor, error: error)
            }

            // Position order in `eventsInSeqOrder`/`exclusionsInSeqOrder` stands in for
            // `server_seq` — everything past `cursor.events`/`.exclusions` (by index) is "new."
            let allEvents = eventsInSeqOrder
            let eventsFromCursor = Array(allEvents.enumerated().filter { $0.offset >= cursor.events })
            let eventPage = Array(eventsFromCursor.prefix(pageSize))
            let quarantined = eventPage.filter { futureVersionEventIDs.contains($0.element.id) }
            let applicable = eventPage.filter { !futureVersionEventIDs.contains($0.element.id) }

            let allExclusions = exclusionsInSeqOrder
            let exclusionsFromCursor = Array(allExclusions.enumerated().filter { $0.offset >= cursor.exclusions })
            let exclusionPage = Array(exclusionsFromCursor.prefix(pageSize))

            let nextEventsCursor = Int64(eventPage.last?.offset.advanced(by: 1) ?? Int(cursor.events))
            let nextExclusionsCursor = Int64(exclusionPage.last?.offset.advanced(by: 1) ?? Int(cursor.exclusions))
            let hasMore = eventsFromCursor.count > pageSize || exclusionsFromCursor.count > pageSize

            return SyncPullPage(
                changedEvents: applicable.map(\.element),
                deletedEventIDs: Array(deletedEventIDs),
                changedExclusions: exclusionPage.map(\.element),
                quarantinedEventIDs: quarantined.map(\.element.id),
                nextCursor: SyncCursor(events: nextEventsCursor, exclusions: nextExclusionsCursor),
                hasMorePages: hasMore
            )
        }
    }

    func resetLocalAccountState() async {
        lock.withLock { resetCallCount += 1 }
    }

    // MARK: - Test setup helpers

    /// Seeds a record as if another device had already pushed it — appended to the "server"
    /// table directly (not through `push`, which would stamp its own revision/mutation
    /// bookkeeping), so a fresh `pull(cursor: .initial, ...)` picks it up as new.
    func seedRemoteEvent(_ record: EventSyncRecord) {
        lock.lock(); defer { lock.unlock() }
        eventsInSeqOrder.append(record)
    }

    func seedRemoteEventDeletion(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        eventsInSeqOrder.removeAll { $0.id == id }
        deletedEventIDs.insert(id)
    }

    func seedRemoteExclusion(_ record: RecurrenceExclusionSyncRecord) {
        lock.lock(); defer { lock.unlock() }
        exclusionsInSeqOrder.append(record)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        eventsInSeqOrder = []
        deletedEventIDs = []
        exclusionsInSeqOrder = []
        deletedNotificationRuleIDs = []
        appliedMutationIDs = []
        nextEnsureReadyError = nil
        nextPushError = nil
        nextPullError = nil
        futureVersionEventIDs = []
        conflictEventIDs = []
        permanentlyFailingExclusionIDs = []
        permanentlyFailingNotificationRuleDeletionIDs = []
        ensureReadyCallCount = 0
        lastEnsureReadyAccessToken = nil
        pushCallCount = 0
        pullCallCount = 0
        resetCallCount = 0
    }
}
