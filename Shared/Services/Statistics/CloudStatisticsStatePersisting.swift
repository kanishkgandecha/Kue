//
//  CloudStatisticsStatePersisting.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34. The durable local bookkeeping cloud statistics needs: exactly
//  enough to debounce a re-upload of unchanged content and to detect an account switch. A
//  plain JSON file, not a SwiftData model — same reasoning `SyncStatePersisting.swift`'s own
//  header already establishes verbatim: independent of `KueEvent`/`KueTask`/... schema risk,
//  no `VersionedSchema` bump needed. Keyed per account (`accountID`), same shape
//  `SystemSyncStateStore` already uses — requirement E: "account switching must never upload
//  one account's aggregates to another account."
//

import Foundation
import os

nonisolated struct CloudStatisticsPersistentState: Codable, Equatable {
    /// The exact payload most recently uploaded successfully — a re-computed, byte-identical
    /// payload for the same week skips the network call entirely (requirement E/I: "debounce
    /// cloud aggregate uploads where appropriate").
    var lastUploadedPayload: StatisticsAggregatePayload?
    var lastUploadedAt: Date?
}

nonisolated protocol CloudStatisticsStatePersisting: Sendable {
    func load() -> CloudStatisticsPersistentState
    func save(_ state: CloudStatisticsPersistentState)
}

/// File-based, one JSON file per signed-in account id — exact structural mirror of
/// `SystemSyncStateStore` (Shared/Services/Sync/), including its own App-Group/Application-
/// Support/temporary-directory fallback chain on iPhone and its sandboxed-Mac store-relative
/// path. See that type's own header for the full reasoning; not repeated here.
final class SystemCloudStatisticsStateStore: CloudStatisticsStatePersisting, @unchecked Sendable {
    static let shared = SystemCloudStatisticsStateStore()

    var currentAccountID: UUID?
    private let fileURLOverride: URL?
    private let queue = DispatchQueue(label: "com.kanishkgandecha.Kue.cloudstatisticsstate")
    private let logger = Logger(subsystem: "com.kanishkgandecha.Kue", category: "CloudStatisticsState")

    private init() { fileURLOverride = nil }
    init(fileURL: URL) { fileURLOverride = fileURL }

    private func fileURL(for accountID: UUID?) -> URL {
        if let fileURLOverride { return fileURLOverride }
        let filename = "CloudStatisticsState-\(accountID?.uuidString ?? "none").json"
        #if os(macOS)
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

    func load() -> CloudStatisticsPersistentState {
        queue.sync {
            let url = fileURL(for: currentAccountID)
            guard let data = try? Data(contentsOf: url) else { return CloudStatisticsPersistentState() }
            return (try? JSONDecoder().decode(CloudStatisticsPersistentState.self, from: data)) ?? CloudStatisticsPersistentState()
        }
    }

    func save(_ state: CloudStatisticsPersistentState) {
        queue.sync {
            let url = fileURL(for: currentAccountID)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(state)
                try data.write(to: url, options: .atomic)
            } catch {
                // Never include event content, statistics values, or account identifiers.
                logger.fault("Failed to persist cloud statistics bookkeeping: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

final class FakeCloudStatisticsStateStore: CloudStatisticsStatePersisting, @unchecked Sendable {
    private var state = CloudStatisticsPersistentState()
    private let lock = NSLock()

    func load() -> CloudStatisticsPersistentState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func save(_ state: CloudStatisticsPersistentState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}
