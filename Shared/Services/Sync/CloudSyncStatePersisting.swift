//
//  CloudSyncStatePersisting.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "E." The durable local sync-state store: pending record
//  saves/deletions (the outbox), tombstones, last-successful-sync date, persisted
//  `CKSyncEngine` state serialization, an account identity marker, the record-format version,
//  and retry metadata. Deliberately a separate JSON file in the App Group container, not a
//  SwiftData model — docs/26 "E." asks for this explicitly ("separate from the production
//  SwiftData model if possible"), and it means every sync-bookkeeping write is independent of
//  `KueEvent`/`KueTask`/... schema risk entirely (docs/26 "P."). Every write from the app,
//  widgets, Share Extension, App Intents, and notification actions durably updates this file
//  *synchronously after* the local SwiftData save already succeeded — never before, never
//  gated on it (docs/26 primary guarantee: "Cloud failures never prevent local event creation
//  or editing").
//

import Foundation

/// Everything this device remembers about sync state, independent of whether CloudKit is
/// reachable right now. `Codable` — the System store is a plain JSON file; a `Fake` store
/// keeps the identical value in memory, so both sides exercise the exact same shape.
nonisolated struct SyncPersistentState: Codable, Equatable {
    /// Event ids with a local change not yet confirmed uploaded. A `Set`, not a queue —
    /// docs/26 "J.": "multiple sequential edits before upload" must collapse to one pending
    /// upload per event, not one per edit (the *current* graph is always what's re-encoded
    /// and sent, never a replayed history of intermediate edits).
    var pendingEventUploads: Set<UUID> = []
    var pendingExclusionUploads: Set<UUID> = []
    /// Event ids deleted locally, not yet confirmed as deleted in CloudKit.
    var pendingEventDeletions: Set<UUID> = []
    var pendingExclusionDeletions: Set<UUID> = []
    /// docs/26 "E.": tombstones — kept even after a deletion is confirmed uploaded, until
    /// `SyncTombstonePolicy`'s retention window passes, so a late-arriving stale remote save
    /// for the same id (from a device that was offline through the whole deletion) can't
    /// silently resurrect it.
    var eventTombstones: [UUID: Date] = [:]
    var exclusionTombstones: [UUID: Date] = [:]
    var lastSuccessfulSyncAt: Date?
    /// `CKSyncEngine.State.Serialization`, opaque to everything except
    /// `SystemCloudSyncTransport` — persisted here so a relaunch reconstructs pending
    /// CloudKit-side state rather than starting over (docs/26 "G.": "`CKSyncEngine` resets
    /// internal pending state on account changes, so Kue must persist enough local state to
    /// reconstruct pending changes safely" — this field plus the outbox sets above are that
    /// reconstruction).
    var engineStateData: Data?
    /// The account fingerprint (`CloudAccountProviding.currentAccountFingerprint()`) sync last
    /// ran successfully under — compared against the *current* fingerprint to detect an
    /// account switch (docs/26 "G."). Never an Apple ID/name — see that protocol's own header.
    var accountFingerprint: String?
    var recordFormatVersion: Int = SyncRecordFormat.currentEventFormatVersion
    /// Set from a CloudKit rate-limit response's `retryAfterSeconds` (docs/26 "N.") — sync
    /// work is skipped until this passes, never retried in a tight loop.
    var retryNotBefore: Date?
    /// Kue 2.0 Phase 11 — docs/26 "F.": once a user has made an explicit sync decision
    /// (enabled, or explicitly kept local-only after a merge prompt), this is set so a later
    /// launch never re-shows the initial-sync decision unprompted.
    var hasCompletedInitialSyncDecision = false
}

nonisolated protocol CloudSyncStatePersisting: Sendable {
    func load() -> SyncPersistentState
    func save(_ state: SyncPersistentState)
}

/// File-based, App Group-scoped, JSON — never in-memory-only (docs/26 "E."). One flat file,
/// read-modify-written wholesale; Kue's realistic pending-change volume (a personal event
/// planner, not a high-throughput sync target) makes a plain file the right-sized tool here —
/// no embedded database needed for a structure this small.
final class SystemCloudSyncStateStore: CloudSyncStatePersisting, @unchecked Sendable {
    static let shared = SystemCloudSyncStateStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.kanishkgandecha.Kue.syncstate")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ModelContainerFactory.appGroupIdentifier) {
            self.fileURL = containerURL.appendingPathComponent("SyncState.json")
        } else {
            // Matches `ModelContainerFactory.storeURL()`'s own fallback shape — still
            // functions (degraded to per-process, not App-Group-shared) rather than crashing.
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncState.json")
        }
    }

    func load() -> SyncPersistentState {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return SyncPersistentState() }
            return (try? JSONDecoder().decode(SyncPersistentState.self, from: data)) ?? SyncPersistentState()
        }
    }

    func save(_ state: SyncPersistentState) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

final class FakeCloudSyncStateStore: CloudSyncStatePersisting, @unchecked Sendable {
    private var state = SyncPersistentState()
    private let lock = NSLock()

    func load() -> SyncPersistentState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func save(_ state: SyncPersistentState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}
