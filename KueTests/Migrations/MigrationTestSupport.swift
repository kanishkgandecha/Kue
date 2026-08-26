//
//  MigrationTestSupport.swift
//  KueTests
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation, requirement 7: reusable migration-test
//  infrastructure. Every store this file creates lives at a throwaway temporary URL —
//  **never** `ModelContainerFactory.storeURL()` — so a migration test can never touch a real
//  App Group store, in this phase or any future one. `KueSchemaV2MigrationTests` (whenever it
//  exists) should reuse these helpers rather than re-deriving its own temp-store plumbing.
//

import Foundation
import SwiftData
@testable import Kue

enum MigrationTestSupport {
    /// A fresh, unique, on-disk location for one test's store — never the real App Group
    /// path. Callers should `removeStore(at:)` when done, though a leaked temp file is
    /// harmless (the OS reclaims `/tmp` eventually) and never risks production data either
    /// way, unlike a mistake that touched the real store URL would.
    static func makeTemporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KueMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Kue.sqlite")
    }

    static func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Creates a store at `url` using *only* `KueSchemaV1`'s schema, with no migration plan
    /// at all — this is exactly how every real V1.0 store on a user's device was actually
    /// created (`ModelContainerFactory.schema` had no `VersionedSchema`/`SchemaMigrationPlan`
    /// wired in until this phase). A migration test should always start from a store built
    /// this way, not one already opened through `KueMigrationPlan`, so "reopen through the
    /// current migration plan" (below) is proven against a genuinely pre-migration-aware
    /// store, not a lookalike.
    static func makeV1Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KueSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Reopens the store at `url` through `ModelContainerFactory`'s own current
    /// `schema`/`migrationPlan` — the *exact* construction path every production target
    /// (Kue app, KueWidget, KueShare) uses, not a parallel one a test invented. This is the
    /// one call that actually exercises "does the shipped v1.0 store open without loss
    /// through a real migration plan."
    static func reopenThroughCurrentMigrationPlan(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: ModelContainerFactory.schema, url: url)
        return try ModelContainer(
            for: ModelContainerFactory.schema,
            migrationPlan: ModelContainerFactory.migrationPlan,
            configurations: [configuration]
        )
    }
}
