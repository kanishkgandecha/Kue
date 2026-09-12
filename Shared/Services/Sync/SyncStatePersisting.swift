//
//  SyncStatePersisting.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33. The durable local sync-state store: outbox (pending saves/
//  deletions), tombstones, cursors, known revisions, last-successful-sync date, and retry
//  metadata. Renamed from Kue 2.0 Phase 11's `CloudSyncStatePersisting` (docs/26 "E.") — same
//  file's own reasoning still applies verbatim: a plain JSON file, not a SwiftData model, so
//  every sync-bookkeeping write is independent of `KueEvent`/`KueTask`/... schema risk and
//  needs no `VersionedSchema` bump of its own. Every write from the app, widgets, Share
//  Extension, App Intents, and notification actions durably updates this file *synchronously
//  after* the local SwiftData save already succeeded — never before, never gated on it.
//
//  Kue 3.0 Phase 5 — docs/33 "Account lifecycle": keyed *per account* (`accountID`, the
//  Supabase `auth.users` uuid), not one flat file — requirement L: "store sync cursors and
//  fingerprints per account," so switching accounts on one device can never let Account A's
//  cursor/outbox position leak into Account B's sync.
//

import Foundation
import os

/// Everything this device remembers about sync state for one signed-in account, independent of
/// whether the network is reachable right now.
nonisolated struct SyncPersistentState: Codable, Equatable {
    /// Event ids with a local change not yet confirmed pushed. A `Set`, not a queue — multiple
    /// sequential edits before a successful push collapse to one pending upload per event; the
    /// *current* graph is always what's re-encoded and sent, never a replayed edit history.
    var pendingEventUploads: Set<UUID> = []
    var pendingExclusionUploads: Set<UUID> = []
    var pendingEventDeletions: Set<UUID> = []
    /// Requirement I: "an explicit tombstone mechanism for Notification Rules rather than
    /// inferring deletion from absence" — a rule id deleted locally, pushed as its own explicit
    /// deletion call independent of whatever its owning event's next graph push happens to
    /// contain.
    var pendingNotificationRuleDeletions: Set<UUID> = []
    /// Kept even after a deletion is confirmed pushed, until `SyncOutbox.tombstoneRetention`
    /// passes, so a late-arriving stale remote save for the same id (from a device that was
    /// offline through the whole deletion) can't silently resurrect it.
    var eventTombstones: [UUID: Date] = [:]
    var exclusionTombstones: [UUID: Date] = [:]
    var lastSuccessfulSyncAt: Date?
    /// The last server-assigned revision this device knows about for a given event id —
    /// requirement K: "server revision... as the ordering authority." Sent back as
    /// `expectedRevision` on that id's next push (optimistic concurrency); updated on every
    /// successful push acknowledgement *and* every applied pull.
    var knownEventRevisions: [UUID: Int64] = [:]
    /// requirement H: "server-controlled monotonically ordered cursor... persisted only after a
    /// page is safely applied... resumable after interruption."
    var pullCursor: SyncCursor = .initial
    /// Requirement J: has this account completed (or explicitly deferred) the first-sync
    /// decision? `nil` means "never asked" — the first-sync UI is shown; `false` means
    /// "asked, chose Not Now" — sync stays off but the question isn't re-asked unprompted;
    /// `true` means an explicit choice was made and applied.
    var hasCompletedInitialSyncDecision = false
    /// docs/33 "Background behavior": consecutive transient-failure count, reset to 0 on any
    /// successful sync pass — feeds `SyncCoordinator`'s exponential-backoff delay calculation.
    var consecutiveFailureCount = 0
    /// Set from a rate-limit response's `retryAfterSeconds`, or computed backoff on a bare
    /// transient failure — sync work is skipped until this passes, never retried in a tight loop.
    var retryNotBefore: Date?
}

nonisolated protocol SyncStatePersisting: Sendable {
    func load() -> SyncPersistentState
    func save(_ state: SyncPersistentState)
}

/// File-based, one JSON file per signed-in account id, in the App Group container on iPhone
/// (falls back to `Application Support`, then a per-process temporary location, if the App
/// Group is unreachable — same `ModelContainerFactory.storeURL()` fallback shape) or
/// `Application Support` directly on Mac (no App Group there at all — docs/29 "C.", unrelated
/// to sync, sync doesn't change that boundary).
///
/// A mutable singleton, not a per-account-constructed instance — every existing Kue 2.0 Phase
/// 11 mutation call site (`EventActions`, `WidgetIntentActions`, `EventCreationService`, ...,
/// dozens of them across the app/widgets/Share Extension/App Intents) already calls
/// `SyncOutbox.markEventDirty(id)` with *no* explicit store argument, relying on a shared
/// default. Rather than thread an account identity through every one of those call sites for
/// Phase 5, `currentAccountID` is updated in exactly one place (`SyncCoordinator`, whenever the
/// signed-in account changes) and every `load()`/`save(_:)` call resolves against whichever
/// account is current *at the time of the call* — requirement L: "store sync cursors and
/// fingerprints per account," achieved without an invasive DI change to unrelated call sites.
final class SystemSyncStateStore: SyncStatePersisting, @unchecked Sendable {
    static let shared = SystemSyncStateStore()

    /// `nil` while signed out — `load()`/`save(_:)` still work (resolving to a fixed
    /// "no account" file) but `SyncCoordinator` never actually calls into a transport without a
    /// session, so this file is never meaningfully read/written while signed out in practice.
    var currentAccountID: UUID?

    /// Test-only escape hatch — a fixed file, ignoring `currentAccountID` entirely, so a
    /// durability test (`SystemSyncStateStore` really does persist to disk across instances)
    /// never touches the real App-Group/`Application Support` location `.shared` resolves to.
    private let fileURLOverride: URL?

    private let queue = DispatchQueue(label: "com.kanishkgandecha.Kue.syncstate")
    private let logger = Logger(subsystem: "com.kanishkgandecha.Kue", category: "SyncState")

    private init() { fileURLOverride = nil }

    init(fileURL: URL) { fileURLOverride = fileURL }

    private func fileURL(for accountID: UUID?) -> URL {
        if let fileURLOverride { return fileURLOverride }
        let filename = "SyncState-\(accountID?.uuidString ?? "none").json"
        #if os(macOS)
        // A sandboxed Mac app must keep this beside its private SwiftData store. Asking for
        // the generic Application Support directory here used to resolve inconsistently when
        // Kue was launched by Xcode, and `save` then swallowed the denied write. The store URL
        // has already resolved the correct sandbox container, so its parent is authoritative.
        return ModelContainerFactory.storeURL().deletingLastPathComponent().appendingPathComponent(filename)
        #else
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ModelContainerFactory.appGroupIdentifier) {
            return containerURL.appendingPathComponent(filename)
        } else if let supportURL = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            return supportURL.appendingPathComponent(filename)
        } else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }
        #endif
    }

    func load() -> SyncPersistentState {
        queue.sync {
            let url = fileURL(for: currentAccountID)
            guard let data = try? Data(contentsOf: url) else { return SyncPersistentState() }
            return (try? JSONDecoder().decode(SyncPersistentState.self, from: data)) ?? SyncPersistentState()
        }
    }

    func save(_ state: SyncPersistentState) {
        queue.sync {
            let url = fileURL(for: currentAccountID)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(state)
                try data.write(to: url, options: .atomic)
            } catch {
                // Never include event content or account identifiers in logs.
                logger.fault("Failed to persist sync bookkeeping: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

final class FakeSyncStateStore: SyncStatePersisting, @unchecked Sendable {
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
