//
//  SyncConflictResolver.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "H." A pure function: given what this
//  device knows locally about one event and what the remote side currently says, decide the
//  one outcome. No SwiftData, no CloudKit, no I/O — exhaustively unit-testable, and the only
//  place this decision is made (`SyncCoordinator` calls this once per changed event, never
//  re-derives the policy inline).
//
//  Baseline policy (docs/26 "H."):
//   - the same stable UUID identifies the same logical object
//   - compare `updatedAt` — later wins
//   - equal timestamps use a deterministic, content-based tie-break, never device-dependent
//     order (running the same comparison on either device must agree)
//   - a deletion tombstone beats an equal-or-older save; a strictly newer explicit save/
//     restore beats an older tombstone
//   - whole-graph resolution only (docs/26 "H.": "do not attempt unsafe field-by-field
//     merging") — one event's entire local graph either wins or loses together, never a
//     per-field splice
//

import Foundation
import CryptoKit

nonisolated enum SyncConflictResolver {
    /// What this device currently believes about one event, before consulting the remote
    /// side. `.tombstone` is a *local* deletion this device already knows about (from its own
    /// delete, or from having previously applied a remote one) — distinct from `.absent`
    /// (never existed here, or a tombstone old enough to have been pruned).
    enum LocalState: Equatable {
        case record(EventSyncRecord)
        case tombstone(deletedAt: Date)
        case absent
    }

    /// What CloudKit's zone currently says about the same event id. `.unknown` means "this
    /// event id has no remote change to consider right now" (e.g. resolving a purely local
    /// mutation before its first upload) — resolution in that case is always `.keepLocal`.
    enum RemoteState: Equatable {
        case record(EventSyncRecord)
        case tombstone(deletedAt: Date)
        case unknown
    }

    enum Resolution: Equatable {
        /// Nothing changes locally. If `local` was a live record, it's still the one to
        /// (re-)upload — the remote side was stale or absent.
        case keepLocal
        /// Overwrite the local graph with `record` (docs/26 "H." whole-graph rule).
        case applyRemote(EventSyncRecord)
        /// Delete the local event; a remote tombstone wins.
        case deleteLocal
        /// The local record is *newer* than a remote tombstone — undoes the remote deletion
        /// by re-uploading `record` (docs/26 "H.": "a newer explicit restore may supersede an
        /// older tombstone").
        case restoreLocal(EventSyncRecord)
    }

    static func resolve(local: LocalState, remote: RemoteState) -> Resolution {
        switch (local, remote) {
        case (_, .unknown):
            return .keepLocal

        // MARK: Remote has a live record
        case (.absent, .record(let remoteRecord)):
            return .applyRemote(remoteRecord)

        case (.record(let localRecord), .record(let remoteRecord)):
            guard localRecord.id == remoteRecord.id else { return .keepLocal } // never mix identities
            if remoteRecord.updatedAt > localRecord.updatedAt {
                return .applyRemote(remoteRecord)
            } else if localRecord.updatedAt > remoteRecord.updatedAt {
                return .keepLocal
            } else {
                return deterministicWinner(localRecord, remoteRecord) == .remote ? .applyRemote(remoteRecord) : .keepLocal
            }

        case (.tombstone(let deletedAt), .record(let remoteRecord)):
            // A remote edit that happened after this device's own deletion undoes that
            // deletion (someone restored or re-edited it elsewhere) — never re-derive a
            // second identity for it; the same UUID comes back to life.
            return remoteRecord.updatedAt > deletedAt ? .applyRemote(remoteRecord) : .keepLocal

        // MARK: Remote is tombstoned
        case (.absent, .tombstone):
            return .keepLocal // nothing local to reconcile against

        case (.record(let localRecord), .tombstone(let remoteDeletedAt)):
            return localRecord.updatedAt > remoteDeletedAt ? .restoreLocal(localRecord) : .deleteLocal

        case (.tombstone, .tombstone):
            return .keepLocal // both sides already agree
        }
    }

    /// Content-based, device-independent — computed identically regardless of which device
    /// runs it, satisfying docs/26 "H."'s "not a device-dependent order" requirement. Neither
    /// side is inherently favored by construction order; this only ever runs on a genuine
    /// timestamp tie, an intentionally rare case.
    private enum Side { case local, remote }
    private static func deterministicWinner(_ a: EventSyncRecord, _ b: EventSyncRecord) -> Side {
        let hashA = contentHash(a)
        let hashB = contentHash(b)
        return hashA >= hashB ? .local : .remote
    }

    private static func contentHash(_ record: EventSyncRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(record)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
