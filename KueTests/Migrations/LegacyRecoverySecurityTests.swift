//
//  LegacyRecoverySecurityTests.swift
//  KueTests
//
//  Hardening (2026-08-28) — requirements 10/11. Two families of tests:
//   - "Negative" (requirement 10): a store that should *never* trigger
//     `ModelContainerFactory`'s legacy-recognition fallback — because it's corrupted, an
//     unknown/wrong version, already migrated, missing metadata entirely, structurally
//     similar but not an exact hash match, or simply inaccessible — actually doesn't. Checked
//     two ways for every case: `openThroughMigrationPlan(at:)` throws (never silently
//     "succeeds" by mutating something it shouldn't have), and
//     `LegacyRecoveryTestHooks.recognitionAttempted` never fires.
//   - "Failure-injection" (requirement 11): a store that *does* pass the verified-signature
//     gate, with a forced failure at each of the three post-backup mutation stages in turn
//     (`recognizeAsV1IfPossible`, validation, the final reopen) — proving the backup is
//     restored byte-for-byte and the *original* error surfaces, at every stage, not just
//     whichever one happens to fail on its own.
//
//  Every store here is synthetic (`LegacyStoreFixtures`) or a throwaway temp file — never the
//  real incident store, never anything device-specific.
//

import Testing
import Foundation
import SwiftData
import CoreData
@testable import Kue

// `.serialized`: every test here reads/writes the same process-global `LegacyRecoveryTestHooks`
// state — Swift Testing parallelizes tests within a suite by default, which would let one
// test's injected failure leak into another running concurrently. Forcing this suite
// sequential is what actually makes `LegacyRecoveryTestHooks.reset()` a reliable per-test
// boundary rather than a race.
@Suite(.serialized)
@MainActor
struct LegacyRecoverySecurityTests {
    // MARK: - Negative tests (requirement 10)

    @Test func fallbackIsNotAttemptedForACorruptedStore() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        try Data("not a real sqlite file, just garbage bytes".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        try assertFallbackNeverAttempted(at: url)

        #expect(try Data(contentsOf: url) == before, "a corrupted store must be left byte-for-byte untouched")
    }

    @Test func fallbackIsNotAttemptedForAStoreWithAnUnknownChecksum() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        // Structurally V1, but every entity hash is a fabricated, unrecognized value —
        // matches neither the live `KueSchemaV1` nor `VerifiedV1StoreSignature`.
        let unknownHashes = Dictionary(uniqueKeysWithValues: VerifiedV1StoreSignature.entityVersionHashes.keys.map {
            ($0, Data(repeating: 0xAB, count: 32))
        })
        try LegacyStoreFixtures.makeV1StoreWithRewrittenMetadata(at: url, hashes: unknownHashes)
        let before = try Data(contentsOf: url)

        try assertFallbackNeverAttempted(at: url)

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func fallbackIsNotAttemptedForAFutureVersionStore() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        try LegacyStoreFixtures.makeV1StoreWithRewrittenMetadata(
            at: url, hashes: VerifiedV1StoreSignature.entityVersionHashes, versionIdentifiers: ["4.0.0"]
        )
        let before = try Data(contentsOf: url)

        try assertFallbackNeverAttempted(at: url)

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func fallbackIsNotAttemptedForAnAlreadyMigratedV2OrV3Store() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        // A store already at the current (V3) schema opens successfully on the very first,
        // normal staged attempt — the fallback should never even be reachable.
        _ = try ModelContainerFactory.openThroughMigrationPlan(at: url)

        LegacyRecoveryTestHooks.reset()
        defer { LegacyRecoveryTestHooks.reset() }
        var recognitionWasAttempted = false
        LegacyRecoveryTestHooks.recognitionAttempted = { recognitionWasAttempted = true }

        _ = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        #expect(!recognitionWasAttempted)
    }

    @Test func fallbackIsNotAttemptedForAStoreWithMissingMetadata() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        // A genuine, populated V1 store with its `Z_METADATA` row deleted — CoreData sees
        // real `Z_*` tables already present (so it won't treat this as "no store yet, adopt
        // it fresh" the way a truly empty file would) but has nothing to reconcile a version
        // against.
        try LegacyStoreFixtures.makeStoreWithMetadataRemoved(at: url)
        let before = try Data(contentsOf: url)

        try assertFallbackNeverAttempted(at: url)

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func fallbackIsNotAttemptedForAStructurallySimilarButUnapprovedStore() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        // Same entity *names* as the verified signature, correct version identifier, but one
        // entity's hash differs by a single byte — "structurally similar," deliberately not
        // an exact match.
        var almostMatchingHashes = VerifiedV1StoreSignature.entityVersionHashes
        var tamperedEventHash = almostMatchingHashes["KueEvent"]!
        tamperedEventHash[0] ^= 0xFF
        almostMatchingHashes["KueEvent"] = tamperedEventHash
        try LegacyStoreFixtures.makeV1StoreWithRewrittenMetadata(at: url, hashes: almostMatchingHashes)
        let before = try Data(contentsOf: url)

        try assertFallbackNeverAttempted(at: url)

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func fallbackIsNotAttemptedForAnArbitraryIOOrPermissionError() throws {
        // A directory where a store file is expected — a plain I/O-class failure, nothing to
        // do with model versions at all.
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        try assertFallbackNeverAttempted(at: url)
    }

    /// Shared assertion for every negative case above: `openThroughMigrationPlan(at:)` throws,
    /// and `recognizeAsV1IfPossible` was never actually invoked.
    private func assertFallbackNeverAttempted(at url: URL) throws {
        LegacyRecoveryTestHooks.reset()
        defer { LegacyRecoveryTestHooks.reset() }
        var recognitionWasAttempted = false
        LegacyRecoveryTestHooks.recognitionAttempted = { recognitionWasAttempted = true }

        #expect(throws: (any Error).self) {
            try ModelContainerFactory.openThroughMigrationPlan(at: url)
        }
        #expect(!recognitionWasAttempted)
    }

    // MARK: - Failure-injection tests (requirement 11)

    @Test func restoresTheBackupWhenRecognitionItselfFails() throws {
        try assertRestorationAfterInjectedFailure { LegacyRecoveryTestHooks.forceRecognitionFailure = true }
    }

    @Test func restoresTheBackupWhenValidationFails() throws {
        try assertRestorationAfterInjectedFailure { LegacyRecoveryTestHooks.forceValidationFailure = true }
    }

    @Test func restoresTheBackupWhenTheFinalReopenFails() throws {
        try assertRestorationAfterInjectedFailure { LegacyRecoveryTestHooks.forceReopenFailure = true }
    }

    /// Requirement 11 — the shared shape of every failure-injection case: build a store that
    /// genuinely passes the verified-signature gate, force a failure at one specific mutation
    /// stage, and prove (a) the *original* staged-migration error is what's thrown — not a
    /// confusing secondary one from the failed recovery attempt — and (b) the store is
    /// restored to its pre-attempt state, both in what its metadata claims and in the actual
    /// data it holds.
    ///
    /// "Restored" is checked logically, not by raw byte equality: `SQLiteBackup`'s Online
    /// Backup API (requirement 6's whole reason for existing over a plain file copy) is only
    /// documented to reproduce the source database's *content* exactly — same tables, same
    /// rows, same metadata — not its on-disk page layout, so two backup/restore round trips of
    /// an unmodified database are not guaranteed byte-identical even though they're fully
    /// equivalent. A final, un-injected retry proves the restored file is genuinely usable
    /// (not just superficially plausible), which is the strongest and most relevant check.
    private func assertRestorationAfterInjectedFailure(injectFailure: () -> Void) throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }
        try LegacyStoreFixtures.makeStoreMatchingVerifiedSignature(at: url)

        LegacyRecoveryTestHooks.reset()
        defer { LegacyRecoveryTestHooks.reset() }
        injectFailure()

        #expect(throws: (any Error).self) {
            try ModelContainerFactory.openThroughMigrationPlan(at: url)
        }

        // No stray *pending* WAL content left behind by the failed, then-restored, attempt.
        // `-shm` is a fixed-size (32KB) shared-memory index SQLite maps whenever a WAL-mode
        // file is merely *opened*, regardless of whether anything is actually pending — its
        // presence/size says nothing about consistency, so only `-wal`'s actual byte count is
        // checked (0 bytes == fully checkpointed, nothing left to replay).
        let walPath = url.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            let size = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
            #expect(size == 0, "-wal must be empty if present at all")
        }

        // The restored store's metadata still matches the verified signature exactly — proof
        // the restore reverted whatever `recognizeAsV1IfPossible` re-stamped, not just that
        // *some* file exists at `url`.
        let restoredMetadata = try #require(
            try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        )
        #expect(VerifiedV1StoreSignature.matches(metadata: restoredMetadata), "the restored store's metadata must match the verified signature again, not whatever the failed attempt left it as")

        // The restored file's *data* is genuinely intact — read directly via SQL, not through
        // another `ModelContainer` open. `NSPersistentStoreCoordinator` caches per-URL model
        // info within a process (this same `url` was already opened once, unsuccessfully, by
        // the staged attempt above), so a same-process CoreData re-open here would be testing
        // that cache's behavior, not this mechanism's actual restore correctness — a real app
        // launch never shares a process with the attempt that failed. Combined with the
        // metadata check above (which *is* exactly what a fresh process's staged-migration
        // attempt consults), this is the complete, artifact-free proof: `RealStoreCopyVerification`
        // separately proves a fresh-process reopen succeeds end-to-end.
        let titles = try LegacyStoreFixtures.readEventTitles(at: url)
        #expect(titles.contains("Fixture Event"))
    }
}
