//
//  SyncRecordFormat.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33. A record-format version independent of
//  `ModelContainerFactory.schema`'s own local `VersionedSchema` — the *synced payload* shape
//  can change on its own timeline, separate from Kue's local SwiftData shape. Bumping this is
//  how a future Kue version marks "the payload shape changed in a way older Kue builds can't
//  safely interpret," independent of whether the local store also happened to gain a migration
//  that release. Inherited unchanged from Kue 2.0 Phase 11's own `SyncRecordFormat` (docs/26
//  "C./O.") minus the CloudKit-specific zone/record-type naming this phase retires.
//

import Foundation

nonisolated enum SyncRecordFormat {
    /// Bumped whenever `EventSyncRecord`/`RecurrenceExclusionSyncRecord`'s encoded shape
    /// changes in a way an older Kue build genuinely can't interpret (not merely "gained an
    /// optional field with a safe default" — additive fields never need a bump, tolerant
    /// decoding already handles those). A record whose own stamped version is *greater* than
    /// this is quarantined, never partially applied or force-decoded.
    static let currentEventFormatVersion = 1
    static let currentRecurrenceExclusionFormatVersion = 1
}
