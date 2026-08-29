//
//  FakeCloudSyncTransport.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "R./S." Deterministic in-memory "CloudKit" — a `Dictionary`
//  standing in for the private custom zone, plus test-controlled error/latency injection. No
//  real network, no real account, ever. Used by `KueTests`/`KueUITests` and nowhere else.
//
//  `@unchecked Sendable` — internally serialized by `lock`, same shape
//  `FakeLiveActivityManager`/`FakeSpotlightIndexer` already use for their own test doubles.
//

import Foundation

final class FakeCloudSyncTransport: CloudSyncTransporting, @unchecked Sendable {
    private let lock = NSLock()

    private(set) var events: [UUID: EventSyncRecord] = [:]
    private(set) var exclusions: [UUID: RecurrenceExclusionSyncRecord] = [:]
    private(set) var deletedEventIDs: Set<UUID> = []
    private(set) var deletedExclusionIDs: Set<UUID> = []

    /// Records not yet "fetched" by this device — simulates another device's changes sitting
    /// in the zone until this device's own `fetchChanges()` call picks them up, so a test can
    /// seed remote state and assert it's inert until fetched.
    private(set) var pendingRemoteEvents: [EventSyncRecord] = []
    private(set) var pendingRemoteEventDeletions: Set<UUID> = []
    private(set) var pendingRemoteExclusions: [RecurrenceExclusionSyncRecord] = []
    private(set) var pendingRemoteExclusionDeletions: Set<UUID> = []

    /// Test-injected outcomes — set before calling into `SyncCoordinator`, consumed (and
    /// cleared, single-shot) by the next matching call, so a test can simulate "fails once,
    /// then succeeds on retry" without hand-rolling a state machine per case.
    var nextSendError: SyncTransportError?
    var nextFetchError: SyncTransportError?
    var nextEnsureZoneError: SyncTransportError?
    /// Simulates docs/26 "O.": a remote record already stamped with a future format version
    /// this "build" can't decode — surfaced as a quarantined id, never applied.
    var futureVersionEventIDs: Set<UUID> = []

    var ensureZoneCallCount = 0
    var sendCallCount = 0
    var fetchCallCount = 0
    var resetCallCount = 0

    func ensureZoneExists() async -> Result<Void, SyncTransportError> {
        lock.withLock {
            ensureZoneCallCount += 1
            if let error = nextEnsureZoneError {
                nextEnsureZoneError = nil
                return .failure(error)
            }
            return .success(())
        }
    }

    func send(
        eventSaves: [EventSyncRecord],
        eventDeletions: [UUID],
        exclusionSaves: [RecurrenceExclusionSyncRecord],
        exclusionDeletions: [UUID]
    ) async -> SyncSendResult {
        lock.withLock {
            sendCallCount += 1
            if let error = nextSendError {
                nextSendError = nil
                if case .rateLimited(let seconds) = error {
                    return SyncSendResult(retryNotBefore: Date().addingTimeInterval(seconds))
                }
                let failedEvents = eventSaves.map { SyncFailedItem(id: $0.id, error: error) }
                let failedExclusions = exclusionSaves.map { SyncFailedItem(id: $0.id, error: error) }
                return SyncSendResult(failedEvents: failedEvents, failedExclusions: failedExclusions)
            }

            for record in eventSaves { events[record.id] = record; deletedEventIDs.remove(record.id) }
            for id in eventDeletions { events.removeValue(forKey: id); deletedEventIDs.insert(id) }
            for record in exclusionSaves { exclusions[record.id] = record; deletedExclusionIDs.remove(record.id) }
            for id in exclusionDeletions { exclusions.removeValue(forKey: id); deletedExclusionIDs.insert(id) }

            return SyncSendResult(
                succeededEventIDs: Set(eventSaves.map(\.id)),
                succeededEventDeletionIDs: Set(eventDeletions),
                succeededExclusionIDs: Set(exclusionSaves.map(\.id)),
                succeededExclusionDeletionIDs: Set(exclusionDeletions)
            )
        }
    }

    func fetchChanges() async -> SyncFetchResult {
        lock.withLock {
            fetchCallCount += 1
            if let error = nextFetchError {
                nextFetchError = nil
                return SyncFetchResult(error: error)
            }

            let quarantinedEvents = pendingRemoteEvents.filter { futureVersionEventIDs.contains($0.id) }
            let applicableEvents = pendingRemoteEvents.filter { !futureVersionEventIDs.contains($0.id) }

            let result = SyncFetchResult(
                changedEvents: applicableEvents,
                deletedEventIDs: Array(pendingRemoteEventDeletions),
                changedExclusions: pendingRemoteExclusions,
                deletedExclusionIDs: Array(pendingRemoteExclusionDeletions),
                quarantinedEventIDs: quarantinedEvents.map(\.id)
            )
            pendingRemoteEvents = []
            pendingRemoteEventDeletions = []
            pendingRemoteExclusions = []
            pendingRemoteExclusionDeletions = []
            return result
        }
    }

    func resetEngineState() async {
        lock.withLock { resetCallCount += 1 }
    }

    // MARK: - Test setup helpers

    /// Seeds a record as if another device had already uploaded it — invisible to `events`
    /// (the "already fetched" view) until `fetchChanges()` picks it up.
    func seedRemoteEvent(_ record: EventSyncRecord) {
        lock.lock(); defer { lock.unlock() }
        pendingRemoteEvents.append(record)
    }

    func seedRemoteEventDeletion(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        pendingRemoteEventDeletions.insert(id)
    }

    func seedRemoteExclusion(_ record: RecurrenceExclusionSyncRecord) {
        lock.lock(); defer { lock.unlock() }
        pendingRemoteExclusions.append(record)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        events = [:]
        exclusions = [:]
        deletedEventIDs = []
        deletedExclusionIDs = []
        pendingRemoteEvents = []
        pendingRemoteEventDeletions = []
        pendingRemoteExclusions = []
        pendingRemoteExclusionDeletions = []
        nextSendError = nil
        nextFetchError = nil
        nextEnsureZoneError = nil
        futureVersionEventIDs = []
        ensureZoneCallCount = 0
        sendCallCount = 0
        fetchCallCount = 0
        resetCallCount = 0
    }
}
