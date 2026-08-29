//
//  SyncRecordFormat.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "C./O." A record-format version
//  independent of `ModelContainerFactory.schema`'s own `KueSchemaV3` — CloudKit production
//  schemas are additive-only and evolve on Apple's own timeline, separate from Kue's local
//  SwiftData shape. Bumping this is how a future Kue version marks "the payload shape changed
//  in a way older Kue builds can't safely interpret," independent of whether the *local*
//  store also happened to gain a migration that release.
//

import Foundation

nonisolated enum SyncRecordFormat {
    /// CloudKit's own custom record zone, private to Kue, private database only (docs/26
    /// primary guarantees: "Private database only," "No collaboration... in this phase").
    static let zoneName = "KueZone"

    /// Two record types only — see docs/26 "C." for the audit reasoning: `KueTask`/
    /// `KueSchedule`/`WidgetConfiguration` have no identity independent of their owning
    /// `KueEvent` (always fetched/mutated through it), so they travel as one CKRecord with
    /// their parent rather than as separate record types with cross-record reference
    /// ordering to reconstruct — this is both simpler and safer (docs/26 "H.": "do not
    /// attempt unsafe field-by-field merging... whole-graph resolution is the safe default").
    /// `RecurrenceExclusion` has no such parent (keyed by `seriesID`, not an event UUID), so
    /// it does need its own record type.
    enum RecordType {
        static let event = "Event"
        static let recurrenceExclusion = "RecurrenceExclusion"
    }

    /// Bumped whenever `EventSyncRecord`/`RecurrenceExclusionSyncRecord`'s encoded shape
    /// changes in a way an older Kue build genuinely can't interpret (not merely "gained an
    /// optional field with a safe default" — additive fields never need a bump, tolerant
    /// decoding already handles those). A record whose own stamped version is *greater* than
    /// this is quarantined (docs/26 "O."), never partially applied or force-decoded.
    static let currentEventFormatVersion = 1
    static let currentRecurrenceExclusionFormatVersion = 1
}
