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
//  Kue 3.0 Phase 3 (docs/31-kue-3-notification-studio.md "Migration") added the third stage:
//  `KueSchemaV3` → `KueSchemaV4`, adding the brand-new `NotificationRule` model and a new
//  (empty-by-construction) relationship from `KueEvent`/`KueTask` to it. `.lightweight` here —
//  unlike the two stages above — because there is no existing data of the new shape to
//  transform or backfill; every event's `notificationRules` array is simply empty until a user
//  explicitly customizes something. See `KueSchemaV4.swift`'s own header for why "preserve
//  existing reminder behavior" is a `NotificationPlanner`/`NotificationGlobalPreferences`
//  guarantee, not a data-migration concern.
//
//  Kue 3.0 Phase 3 completion pass added the fourth stage: `KueSchemaV4` → `KueSchemaV5`,
//  adding `Template.notificationRuleDefaultsData`. `.custom`, not `.lightweight` — deliberately,
//  matching `migrateV1toV2`'s own precedent, not `migrateV3toV4`'s: this is a **non-optional**
//  `Data` property with no schema-level default SwiftData's own lightweight inference can
//  safely fill in for already-existing `Template` rows (`KueSchemaV1`'s own header already
//  documents this exact "non-optional attribute" case as the reason `.custom` was chosen over
//  `.lightweight` the first time) — unlike `migrateV3toV4`'s new *relationship*
//  (`[NotificationRule]`), which starts as a genuinely empty array with no encoding step
//  involved at all. Every migrated `Template` row (there are normally zero in a live user's
//  store — Template rows are created lazily by `TemplateStore`, never eagerly — but a
//  backup-restored or otherwise pre-existing row must still migrate losslessly) is explicitly
//  backfilled to an empty, validly-JSON-encoded `[NotificationRuleDefault]`.
//

import SwiftData
import Foundation

enum KueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KueSchemaV1.self, KueSchemaV2.self, KueSchemaV3.self, KueSchemaV4.self, KueSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
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
            // Kue 3.0 Phase 3 fix — `context` here holds `KueSchemaV3`-shaped objects. Before
            // this phase, `KueSchemaV3.models` referenced the *live* `KueEvent` directly (no
            // nesting), so this unqualified fetch happened to match; now that `KueSchemaV3` has
            // its own nested `KueEvent` (see that file's header), this must fetch the nested
            // type explicitly — the same reason `migrateV1toV2` above fetches
            // `KueSchemaV2.KueEvent`, not a bare `KueEvent`. An unqualified fetch here crashes
            // with "Failed to cast model Kue.KueEvent ... to KueEvent" — found and fixed via a
            // real migration-test run, not assumed.
            let events = try context.fetch(FetchDescriptor<KueSchemaV3.KueEvent>())
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

    /// `.lightweight` — see `KueSchemaV4.swift`'s own header for why no data transformation is
    /// needed: `NotificationRule` is a brand-new, empty table, and every existing event/task's
    /// new `notificationRules` relationship simply starts as an empty array.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: KueSchemaV3.self,
        toVersion: KueSchemaV4.self
    )

    /// `.custom` — see this file's own header for why a non-optional `Data` property needs an
    /// explicit backfill rather than `.lightweight` inference.
    static let migrateV4toV5 = MigrationStage.custom(
        fromVersion: KueSchemaV4.self,
        toVersion: KueSchemaV5.self,
        willMigrate: nil,
        didMigrate: { context in
            let templates = try context.fetch(FetchDescriptor<Template>())
            for template in templates {
                template.notificationRuleDefaults = []
            }
            try context.save()
        }
    )
}
