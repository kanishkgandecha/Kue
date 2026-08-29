//
//  SyncPreferenceTestLock.swift
//  KueTests
//
//  Kue 2.0 Phase 12 — docs/28 regression audit. `SyncPreference` is real, process-global App
//  Group `UserDefaults` state (Shared/Services/Sync/SyncPreference.swift). Swift Testing runs
//  different `@Suite`s concurrently with each other by default — `.serialized` (used by
//  `SyncCoordinatorTests`/`CloudKitSchemaSafetyTests`) only serializes tests *within* one
//  suite, never across suites. Found via a real combined run: `CloudKitSchemaSafetyTests`
//  flipping `SyncPreference` mid-run made `SyncCoordinatorTests.
//  temporarilyUnavailableAccountIsReportedHonestlyNotAsSignedOut()` observe `.off` instead of
//  the account state it had set up — a genuine pre-existing cross-suite race, not a one-off
//  flake (100% reproducible once these two suites ran together). Every test that mutates
//  `SyncPreference` must run its body inside `SyncPreferenceTestLock.shared.withLock`.
//

import Testing

actor SyncPreferenceTestLock {
    static let shared = SyncPreferenceTestLock()

    private var isLocked = false

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while isLocked {
            await Task.yield()
        }
        isLocked = true
        defer { isLocked = false }
        return try await body()
    }
}

/// A `SuiteTrait` so `@Suite(.syncPreferenceSerialized)` brackets *every* test in that suite
/// with the same lock `SyncPreferenceTestLock` — the mechanism that actually makes two
/// unrelated suites (`SyncCoordinatorTests`, `CloudKitSchemaSafetyTests`) mutually exclusive,
/// which plain `.serialized` (per-suite only) can't do.
struct SyncPreferenceSerialized: SuiteTrait, TestScoping {
    @concurrent
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await SyncPreferenceTestLock.shared.withLock {
            try await function()
        }
    }
}

extension Trait where Self == SyncPreferenceSerialized {
    static var syncPreferenceSerialized: Self { SyncPreferenceSerialized() }
}
