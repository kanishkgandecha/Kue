//
//  EventActionsSyncOutboxTestLock.swift
//  KueTests
//
//  Kue 2.0 Phase 12 — docs/28 regression audit. Every `EventActions`/`OccurrenceReconciliationService`
//  mutation (`skip`, `complete`, `cancel`, `archive`, `delete`, `applyEdit`, ...) calls
//  `SyncOutbox.markEventDirty`/`markEventDeleted` with that function's *default* `store:`
//  parameter — the real, process-global, file-backed `SystemCloudSyncStateStore.shared` — since
//  neither `EventActions` nor `OccurrenceReconciliationService` exposes a way to inject a
//  `FakeCloudSyncStateStore` through their own public API. Swift Testing runs different `@Suite`s
//  concurrently by default, so every suite below (found via a full combined-suite run, the same
//  way the `SyncPreference`/`LegacyRecoveryTestHooks` races were found — see
//  `SyncPreferenceTestLock.swift`/`MigrationStoreTestLock.swift`) was intermittently observing
//  another suite's in-flight write to that same real file. Same fix shape: a shared cross-suite
//  lock, applied to every suite that calls into `EventActions`/`OccurrenceReconciliationService`
//  without a fake store.
//

import Testing

actor EventActionsSyncOutboxTestLock {
    static let shared = EventActionsSyncOutboxTestLock()
    private var isLocked = false

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while isLocked { await Task.yield() }
        isLocked = true
        defer { isLocked = false }
        return try await body()
    }
}

struct EventActionsSyncOutboxSerialized: SuiteTrait, TestScoping {
    @concurrent
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await EventActionsSyncOutboxTestLock.shared.withLock { try await function() }
    }
}

extension Trait where Self == EventActionsSyncOutboxSerialized {
    static var eventActionsSyncOutboxSerialized: Self { EventActionsSyncOutboxSerialized() }
}
