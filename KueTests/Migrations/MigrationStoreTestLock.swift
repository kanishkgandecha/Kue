//
//  MigrationStoreTestLock.swift
//  KueTests
//
//  Core Data/SwiftData retain process-wide coordinator/model caches. Migration suites use
//  unique file URLs, but running different schema versions concurrently can still make an
//  injected recovery test observe another suite's coordinator lifecycle. Serialize every
//  migration suite against the same cross-suite lock; `.serialized` alone is suite-local.
//

import Testing

actor MigrationStoreTestLock {
    static let shared = MigrationStoreTestLock()
    private var isLocked = false

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while isLocked { await Task.yield() }
        isLocked = true
        defer { isLocked = false }
        return try await body()
    }
}

struct MigrationStoreSerialized: SuiteTrait, TestScoping {
    @concurrent
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await MigrationStoreTestLock.shared.withLock { try await function() }
    }
}

extension Trait where Self == MigrationStoreSerialized {
    static var migrationStoreSerialized: Self { MigrationStoreSerialized() }
}
