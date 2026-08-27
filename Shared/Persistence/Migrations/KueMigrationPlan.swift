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

import SwiftData
import Foundation

enum KueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KueSchemaV1.self, KueSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: KueSchemaV1.self,
        toVersion: KueSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let events = try context.fetch(FetchDescriptor<KueEvent>())
            for event in events {
                // Every real V1.0 row is non-recurring — explicit, verifiable defaults rather
                // than relying on SwiftData's own inference for newly-added attributes.
                event.seriesID = nil
                event.recurrenceAnchorDate = nil
                event.isRecurrenceException = false
                event.isSkipped = false
                event.skippedAt = nil
            }
            try context.save()
        }
    )
}
