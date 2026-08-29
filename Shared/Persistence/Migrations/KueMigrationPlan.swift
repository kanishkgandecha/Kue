//
//  KueMigrationPlan.swift
//  Kue
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation. See docs/15-schema-migrations.md.
//
//  The single source of truth for "every schema version Kue has ever shipped, in order, and
//  how to get from each to the next."
//
//  Kue 2.0 Phase 3 (docs/17-recurring-events.md "Migration") added the first real stage:
//  `KueSchemaV1` → `KueSchemaV2`, backfilling the new `KueEvent` recurrence fields. `.custom`
//  (not `.lightweight`) was chosen deliberately: this is Kue's first schema migration ever
//  shipped, and an explicit, verifiable `didMigrate` backfill was preferred over relying on
//  SwiftData's inference for a newly-added non-optional attribute. No `willMigrate` step is
//  needed — nothing about the *old* shape needs to be read or transformed before the new
//  columns exist; the new fields are backfilled entirely from fixed defaults, not derived from
//  any V1 data.
//
//  Correction (2026-08-27): `event.recurrence` is now explicitly backfilled to `nil` in
//  `migrateV1toV2` too. It was originally left out of this stage entirely because
//  `KueSchemaV1.KueEvent` was mistakenly believed to already declare it — see
//  `KueSchemaV1.swift`'s header for the real-App-Group-store incident (NSCocoaErrorDomain
//  134504) this was found from. `recurrence` is genuinely new as of `KueSchemaV2`, exactly
//  like the other five fields already backfilled here.
//
//  Kue 2.0 Phase 4 (docs/18-calendar-integration.md "Migration") added the second stage:
//  `KueSchemaV2` → `KueSchemaV3`, backfilling the new Calendar-linkage fields. Every real V1.0
//  and Phase-3 row was created before Calendar integration existed, so every one of them is
//  unlinked by construction — `.custom` again, for the same "explicit and verifiable, not
//  inferred" reasoning as the first stage, even though every new field here is already optional
//  and would default to `nil` under `.lightweight` too.
//

import SwiftData
import Foundation

enum KueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KueSchemaV1.self, KueSchemaV2.self, KueSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: KueSchemaV1.self,
        toVersion: KueSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let events = try context.fetch(FetchDescriptor<KueSchemaV2.KueEvent>())
            for event in events {
                // Every real V1.0 row is non-recurring — explicit, verifiable defaults rather
                // than relying on SwiftData's own inference for newly-added attributes.
                // `recurrence` included: it's genuinely new here, not carried over from V1 —
                // see this file's header.
                event.recurrence = nil
                event.seriesID = nil
                event.recurrenceAnchorDate = nil
                event.isRecurrenceException = false
                event.isSkipped = false
                event.skippedAt = nil
            }
            try context.save()
        }
    )

    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: KueSchemaV2.self,
        toVersion: KueSchemaV3.self,
        willMigrate: nil,
        didMigrate: { context in
            let events = try context.fetch(FetchDescriptor<KueEvent>())
            for event in events {
                // No V1.0 or Phase-3 row was ever linked to a Calendar event — Calendar
                // integration didn't exist yet — so every migrated row is explicitly unlinked.
                event.externalCalendarEventIdentifier = nil
                event.externalCalendarIdentifier = nil
                event.externalCalendarTitle = nil
                event.externalCalendarLastSyncedAt = nil
                event.externalCalendarLastKnownModifiedAt = nil
            }
            try context.save()
        }
    )
}
