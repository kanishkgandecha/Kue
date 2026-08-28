//
//  LegacyStoreFixtures.swift
//  KueTests
//
//  Hardening (2026-08-28), requirement 10/11 support. `VerifiedV1StoreSignature` is tied to
//  one specific real store's historical hash bytes — no schema compiled *today* reproduces
//  them naturally (that's the whole reason `ModelContainerFactory`'s fallback exists at all;
//  see its header). To test the fallback's gate deterministically, without depending on a
//  manually-supplied real-store copy, these helpers build a genuinely V1-shaped store (via the
//  real `KueSchemaV1`, no shortcuts) and then directly rewrite its `Z_METADATA.Z_PLIST` —
//  exactly the same bytes `NSPersistentStoreCoordinator.metadataForPersistentStore` itself
//  reads — to whatever hash set a given test needs, using the SQLite3 C API for the read/write
//  (there is no SwiftData/CoreData API for this; it's the same layer `SQLiteBackup` operates
//  at). This never touches a real device or the original incident store.
//

import Foundation
import SwiftData
import SQLite3
@testable import Kue

enum LegacyStoreFixtures {
    enum FixtureError: Error {
        case cannotOpen
        case noMetadataRow
        case cannotDecodePlist
        case cannotEncodePlist
        case updateFailed
    }

    /// Builds a store using *only* `KueSchemaV1` (genuinely V1-shaped, same as
    /// `MigrationTestSupport.makeV1Store`), inserts one representative event, then rewrites
    /// its recorded `NSStoreModelVersionHashes`/`NSStoreModelVersionIdentifiers` to exactly
    /// `hashes`/`versionIdentifiers` — so the store's *metadata* claims to be whatever the
    /// caller wants, independent of what its *actual* structure naturally hashes to.
    ///
    /// Built at a **separate, throwaway URL** and only plain-file-copied into `url` afterward
    /// — never opened via any SwiftData/CoreData API at `url` itself before the metadata
    /// rewrite. `NSPersistentStoreCoordinator` caches per-URL model info within a process, and
    /// opening `url` with the live schema first (its natural hash) before externally
    /// tampering with that same file's metadata leaves that cache pointing at the *original*
    /// hash — a same-process test artifact a real app launch never hits, since production
    /// only ever meets a given store URL for the first time with whatever metadata a
    /// completely different, long-finished process already wrote to it.
    @MainActor
    static func makeV1StoreWithRewrittenMetadata(
        at url: URL,
        hashes: [String: Data],
        versionIdentifiers: [String] = ["1.0.0"]
    ) throws {
        // No `defer`-cleanup of `stagingURL` here — SQLite's own connection teardown after
        // the `do` block below isn't necessarily synchronous (a WAL-mode `-shm` unmap can
        // trail the container going out of scope), and racing a delete against that can trip
        // "vnode unlinked while in use." `stagingURL` lives in the same directory as `url`
        // (both under `MigrationTestSupport.makeTemporaryStoreURL()`'s own per-test
        // directory), so the caller's own `MigrationTestSupport.removeStore(at:)` teardown
        // removes it too, just not instantly.
        let stagingURL = url.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString).sqlite")

        do {
            let schema = Schema(versionedSchema: KueSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: stagingURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let event = KueSchemaV1.KueEvent(
                title: "Fixture Event", eventType: .generic, startDate: Date(timeIntervalSince1970: 1_700_000_000),
                estimatedDurationMinutes: 0, source: .manual, schemaVersion: 1
            )
            container.mainContext.insert(event)
            try container.mainContext.save()
        }
        // Checkpoint before the plain copy — this *is* a "blindly copy a live database" step,
        // but only ever for a throwaway test fixture never opened again at `stagingURL`, not
        // for anything real; production code never does this (see `SQLiteBackup`).
        try SQLiteBackup.copy(from: stagingURL, to: url)
        try rewriteMetadataHashes(at: url, hashes: hashes, versionIdentifiers: versionIdentifiers)
    }

    /// Same as above, but with EXACTLY `VerifiedV1StoreSignature`'s hashes/identifiers — a
    /// store that is both structurally V1-shaped *and* passes the exact-match gate, letting
    /// failure-injection tests reach `recognizeAsV1IfPossible`/validation deterministically.
    @MainActor
    static func makeStoreMatchingVerifiedSignature(at url: URL) throws {
        try makeV1StoreWithRewrittenMetadata(
            at: url,
            hashes: VerifiedV1StoreSignature.entityVersionHashes,
            versionIdentifiers: Array(VerifiedV1StoreSignature.versionIdentifiers)
        )
    }

    /// A genuine V1-shaped store (every `Z_KUEEVENT`-style table present and populated, built
    /// the same safe, staging-URL way `makeV1StoreWithRewrittenMetadata` is) with its
    /// `Z_METADATA` row removed entirely afterward — a partial/corrupted CoreData store
    /// missing exactly the one table `NSPersistentStoreCoordinator.metadataForPersistentStore`
    /// needs, distinct from both "corrupted bytes" and a truly fresh/empty file (which
    /// CoreData treats as "no store yet" and happily initializes, not an error) —
    /// requirement 10's "missing metadata" case.
    @MainActor
    static func makeStoreWithMetadataRemoved(at url: URL) throws {
        // No `defer`-cleanup of `stagingURL` here — SQLite's own connection teardown after
        // the `do` block below isn't necessarily synchronous (a WAL-mode `-shm` unmap can
        // trail the container going out of scope), and racing a delete against that can trip
        // "vnode unlinked while in use." `stagingURL` lives in the same directory as `url`
        // (both under `MigrationTestSupport.makeTemporaryStoreURL()`'s own per-test
        // directory), so the caller's own `MigrationTestSupport.removeStore(at:)` teardown
        // removes it too, just not instantly.
        let stagingURL = url.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString).sqlite")

        let schema = Schema(versionedSchema: KueSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: stagingURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(KueSchemaV1.KueEvent(
            title: "Fixture Event", eventType: .generic, startDate: Date(timeIntervalSince1970: 1_700_000_000),
            estimatedDurationMinutes: 0, source: .manual, schemaVersion: 1
        ))
        try container.mainContext.save()

        try SQLiteBackup.copy(from: stagingURL, to: url)

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.cannotOpen
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "DELETE FROM Z_METADATA;", nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.updateFailed
        }
    }

    /// Reads every `ZKUEEVENT.ZTITLE` value directly via the SQLite3 C API — bypassing
    /// SwiftData/CoreData entirely, so this has none of `NSPersistentStoreCoordinator`'s
    /// per-process, per-URL model-info caching quirks a same-process `ModelContainer` re-open
    /// of a just-restored file can hit. Used to verify a restored store's *data*, independent
    /// of whether CoreData itself is willing to open it again within this same test process.
    static func readEventTitles(at url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.cannotOpen
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZTITLE FROM ZKUEEVENT", -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.cannotOpen
        }
        defer { sqlite3_finalize(statement) }

        var titles: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                titles.append(String(cString: cString))
            }
        }
        return titles
    }

    /// Directly reads and rewrites `Z_METADATA.Z_PLIST` via the SQLite3 C API — the same
    /// bytes-on-disk `NSPersistentStoreCoordinator.metadataForPersistentStore` itself reads,
    /// so this is exactly as authoritative a way to control what that call reports as
    /// production code ever produces, just driven directly instead of by opening/migrating.
    static func rewriteMetadataHashes(at url: URL, hashes: [String: Data], versionIdentifiers: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.cannotOpen
        }
        defer { sqlite3_close(db) }

        var selectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", -1, &selectStatement, nil) == SQLITE_OK else {
            throw FixtureError.cannotOpen
        }
        defer { sqlite3_finalize(selectStatement) }
        guard sqlite3_step(selectStatement) == SQLITE_ROW else { throw FixtureError.noMetadataRow }
        guard let blob = sqlite3_column_blob(selectStatement, 0) else { throw FixtureError.noMetadataRow }
        let length = Int(sqlite3_column_bytes(selectStatement, 0))
        let plistData = Data(bytes: blob, count: length)

        guard var plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw FixtureError.cannotDecodePlist
        }
        plist["NSStoreModelVersionHashes"] = hashes
        plist["NSStoreModelVersionIdentifiers"] = versionIdentifiers

        guard let newPlistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
            throw FixtureError.cannotEncodePlist
        }

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE Z_METADATA SET Z_PLIST = ?", -1, &updateStatement, nil) == SQLITE_OK else {
            throw FixtureError.updateFailed
        }
        defer { sqlite3_finalize(updateStatement) }
        let bindResult = newPlistData.withUnsafeBytes { rawBuffer -> Int32 in
            sqlite3_bind_blob(updateStatement, 1, rawBuffer.baseAddress, Int32(rawBuffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else { throw FixtureError.updateFailed }
        guard sqlite3_step(updateStatement) == SQLITE_DONE else { throw FixtureError.updateFailed }
    }
}
