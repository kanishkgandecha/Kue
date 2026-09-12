//
//  SyncConflictResolver.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Conflict policy." A pure function: given what this device knows
//  locally about one event and what the remote side currently says, decide the one outcome. No
//  SwiftData, no networking, no I/O — exhaustively unit-testable, and the only place this
//  decision is made (`SyncCoordinator` calls this once per changed event, never re-derives the
//  policy inline). Inherited unchanged in shape from Kue 2.0 Phase 11's own `SyncConflictResolver`
//  (docs/26 "H.") — this phase's real change is what `updatedAt` *means* for the two sides it
//  compares, not the comparison logic itself (see below), plus the new `mergeRecurringOccurrence`
//  helper for the one case whole-graph LWW can lose real user work.
//
//  Baseline policy:
//   - the same stable UUID identifies the same logical object
//   - compare `updatedAt` — later wins. For a *remote* `EventSyncRecord` this is always the
//     server-assigned `server_updated_at` (`SupabaseSyncTransport` stamps it there before this
//     resolver ever sees the record) — never a remote device's own local clock, satisfying
//     "do not trust client clocks as the conflict authority" for the side that matters most
//     (two different devices' clocks disagreeing). The *local* side's `updatedAt` is this
//     device's own `KueEvent.updatedAt` — a deliberate, narrow exception: it is the only signal
//     available for content this device has edited but not yet successfully pushed (the server
//     has no timestamp for a write it's never seen), used only to break a tie against a
//     server-authoritative remote timestamp, never compared against another device's clock
//     directly.
//   - equal timestamps use a deterministic, content-based tie-break, never device-dependent
//     order (running the same comparison on either device must agree)
//   - a deletion tombstone beats an equal-or-older save; a strictly newer explicit save/
//     restore beats an older tombstone
//   - whole-graph resolution is the default (do not attempt unsafe field-by-field merging) —
//     one event's entire local graph either wins or loses together, never a per-field splice —
//     **except** `mergeRecurringOccurrence` below, the one deliberately-scoped exception: see
//     its own header for exactly which two field groups it separates and why.
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

    // MARK: - Recurring-occurrence content/outcome merge (Kue 3.0 Phase 5 — docs/33 "K.")
    //
    // Whole-graph LWW is the right default, but has one real failure mode named explicitly in
    // this phase's own spec: a recurring occurrence's "This and Future Occurrences" content
    // edit (title/schedule/etc.) on one device, racing an offline completion/cancellation/skip
    // of that *same occurrence row* on another device, would otherwise let whichever side has
    // the later `updatedAt` silently discard the other side's real, distinct piece of work —
    // losing a completion is a genuine regression `resolve()`'s own whole-graph rule can't see
    // (it only ever sees "this row" vs "that row," never "which fields actually changed").
    //
    // The exact merge groups, chosen to be disjoint and to cover every field a recurring-
    // occurrence edit is likely to touch independently of its outcome:
    //   content group — title, startDate, endDate, estimatedDurationMinutes, isAllDay,
    //     timeZoneIdentifier, location, notes, priority, recurrence, seriesID,
    //     recurrenceAnchorDate, isRecurrenceException, tasks, schedule, widgetConfiguration,
    //     notificationRules
    //   outcome group — isCancelled/cancelledAt, isManuallyCompleted/manuallyCompletedAt,
    //     isSkipped/skippedAt
    //
    // `ponytail:` this uses the *same* single `updatedAt` timestamp for both groups (no new
    // `outcomeUpdatedAt` field/schema version this phase) — the ceiling that leaves: if BOTH
    // sides genuinely changed BOTH groups, only the later-`updatedAt` side's outcome survives
    // (same as whole-graph LWW would already do). What this *does* fix, unconditionally: an
    // explicit outcome (any of the three flags true) on one side is never silently discarded by
    // a later, purely-content-only edit on the other side that left its own outcome at every
    // field's default — the far more common real case a completed/cancelled/skipped occurrence
    // actually hits. Upgrade path: a dedicated `outcomeUpdatedAt` column (a real schema bump)
    // would let both groups order fully independently instead of relying on this asymmetric
    // "explicit outcome wins over an unedited one" heuristic.
    static func mergeRecurringOccurrence(local: EventSyncRecord, remote: EventSyncRecord) -> EventSyncRecord {
        precondition(local.id == remote.id, "mergeRecurringOccurrence requires the same event id on both sides")
        let contentWinner = remote.updatedAt >= local.updatedAt ? remote : local
        let outcomeWinner = pickOutcomeWinner(local: local, remote: remote)

        var merged = contentWinner
        merged.isCancelled = outcomeWinner.isCancelled
        merged.cancelledAt = outcomeWinner.cancelledAt
        merged.isManuallyCompleted = outcomeWinner.isManuallyCompleted
        merged.manuallyCompletedAt = outcomeWinner.manuallyCompletedAt
        merged.isSkipped = outcomeWinner.isSkipped
        merged.skippedAt = outcomeWinner.skippedAt
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        return merged
    }

    private static func hasExplicitOutcome(_ record: EventSyncRecord) -> Bool {
        record.isCancelled || record.isManuallyCompleted || record.isSkipped
    }

    private static func pickOutcomeWinner(local: EventSyncRecord, remote: EventSyncRecord) -> EventSyncRecord {
        let localHas = hasExplicitOutcome(local)
        let remoteHas = hasExplicitOutcome(remote)
        if localHas && !remoteHas { return local }
        if remoteHas && !localHas { return remote }
        // Both explicit or both default — no asymmetry to exploit; fall back to the same
        // later-`updatedAt`-wins rule the content group already uses (a genuine tie between two
        // explicit-but-different outcomes has no lossless answer without a per-field clock).
        return remote.updatedAt >= local.updatedAt ? remote : local
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
