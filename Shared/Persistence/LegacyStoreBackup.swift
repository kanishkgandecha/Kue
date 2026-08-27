//
//  LegacyStoreBackup.swift
//  Kue
//
//  Hardening (2026-08-28) — requirements 6/7/8. A recoverable, internally consistent backup
//  taken via `SQLiteBackup` (never a raw file copy of a live database — see that file's
//  header) before `ModelContainerFactory`'s legacy-recognition fallback mutates anything, and
//  restorable, in full, if recognition/migration/validation/reopening fails afterward.
//

import Foundation

enum LegacyStoreBackupError: LocalizedError {
    case backupAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .backupAlreadyExists(let url):
            return "Refusing to overwrite an existing backup at \(url.path)."
        }
    }
}

struct LegacyStoreBackup {
    let sourceURL: URL
    let backupURL: URL

    /// Requirement 6/8 — takes a SQLite-safe snapshot of `sourceURL` at a **fresh,
    /// UUID-suffixed path**, so this can never collide with (and so can never silently
    /// overwrite) any prior backup; the existence check below is a defense-in-depth belt, not
    /// the only thing preventing a collision. Throws — leaving `sourceURL` completely
    /// untouched — if the backup can't be created for any reason; callers must never proceed
    /// to a mutating fallback without a successful backup in hand.
    static func create(for sourceURL: URL) throws -> LegacyStoreBackup {
        let directory = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("LegacyStoreBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let backupURL = directory.appendingPathComponent("Kue-legacy-backup-\(UUID().uuidString).sqlite")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw LegacyStoreBackupError.backupAlreadyExists(backupURL)
        }

        try SQLiteBackup.copy(from: sourceURL, to: backupURL)
        return LegacyStoreBackup(sourceURL: sourceURL, backupURL: backupURL)
    }

    /// Requirement 7 — restores `sourceURL` from this backup, SQLite-safe (Online Backup API,
    /// not a raw file copy) in both directions. `sourceURL` must not exist beforehand, mirroring
    /// `SQLiteBackup.copy`'s own never-overwrite contract — the caller (`ModelContainerFactory`)
    /// removes the mutated file first, ensuring every container referencing it has already been
    /// released (requirement 7's "close all containers" before restoring). Any stray
    /// `-wal`/`-shm` sidecars at `sourceURL` are removed too, so the restored file starts in a
    /// clean, fully-checkpointed state — exactly the shape a fresh backup snapshot always is.
    func restore() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: sourceURL.path + suffix)
        }
        try SQLiteBackup.copy(from: backupURL, to: sourceURL)
    }

    /// Removes this backup once it's no longer needed (a successful recovery). Best-effort —
    /// a leaked backup file is inert and harmless, never a correctness or privacy concern
    /// (same App Group container, same access as the store itself), so failure here is never
    /// escalated to the caller.
    func discard() {
        try? FileManager.default.removeItem(at: backupURL)
    }
}
