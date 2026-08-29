//
//  SQLiteBackup.swift
//  Kue
//
//  Hardening (2026-08-28) — requirement 6: "Use a SQLite-safe backup/checkpoint strategy; do
//  not blindly copy a live database." A plain `FileManager.copyItem` of a WAL-mode SQLite
//  database can capture a torn, inconsistent snapshot if a checkpoint is mid-flight, or simply
//  miss committed data still sitting in the `-wal` file rather than the main file. SQLite's
//  own Online Backup API (`sqlite3_backup_init`/`_step`/`_finish`) is the documented, correct
//  way to produce a single, fully self-consistent snapshot of a live database regardless of
//  its current WAL state — it reads through the WAL the same way a normal connection would,
//  and the destination it writes is a complete, standalone file with no `-wal`/`-shm`
//  dependency of its own.
//

import Foundation
import SQLite3

enum SQLiteBackup {
    enum BackupError: LocalizedError {
        case cannotOpenSource(String)
        case cannotOpenDestination(String)
        case cannotInitializeBackup
        case backupStepFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenSource(let message): return "Could not open source database for backup: \(message)"
            case .cannotOpenDestination(let message): return "Could not open destination database for backup: \(message)"
            case .cannotInitializeBackup: return "Could not initialize SQLite backup."
            case .backupStepFailed(let code, let message): return "SQLite backup step failed (code \(code)): \(message)"
            }
        }
    }

    /// Copies `source` to `destination` using SQLite's Online Backup API — safe against a
    /// live, WAL-mode source. `destination` must not already exist; this never overwrites
    /// (requirement 8) — that's a `SQLITE_CANTOPEN`-class failure surfaced as
    /// `.cannotOpenDestination` if the caller didn't already guard against it.
    static func copy(from source: URL, to destination: URL) throws {
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?

        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = sourceDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(sourceDB)
            throw BackupError.cannotOpenSource(message)
        }
        defer { sqlite3_close(sourceDB) }

        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = destinationDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(destinationDB)
            throw BackupError.cannotOpenDestination(message)
        }
        defer { sqlite3_close(destinationDB) }

        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw BackupError.cannotInitializeBackup
        }
        // Kue 2.0 Phase 12 — docs/28 regression audit: SQLite's own Online Backup API docs
        // document `SQLITE_BUSY`/`SQLITE_LOCKED` as expected, transient outcomes of
        // `sqlite3_backup_step` whenever the source is briefly locked by another connection —
        // "it is recommended that the sleeper back off and retry." A full-suite test run (many
        // SwiftData/Core Data stores opening concurrently) surfaced exactly this on a real
        // on-disk store; treating either as a hard failure was always wrong, in tests and on a
        // real device alike (a momentary lock during a real Kue 1.0 → 2.0 upgrade must not fail
        // the whole recovery). -1 == copy every remaining page in one step; small enough
        // databases (this app's) that there's no benefit to chunking it with progress callbacks.
        var stepResult = sqlite3_backup_step(backup, -1)
        var retriesRemaining = 5
        while (stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED), retriesRemaining > 0 {
            retriesRemaining -= 1
            Thread.sleep(forTimeInterval: 0.05)
            stepResult = sqlite3_backup_step(backup, -1)
        }
        let message = destinationDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw BackupError.backupStepFailed(stepResult, message)
        }
        // Requirement 6's "checkpoint strategy": leave the destination itself fully
        // checkpointed too, so it never carries a dangling `-wal` expectation either.
        sqlite3_exec(destinationDB, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }
}
