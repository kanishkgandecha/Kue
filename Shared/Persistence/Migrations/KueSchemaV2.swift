//
//  KueSchemaV2.swift
//  Kue
//
//  Kue 2.0 Phase 3 — Recurring Events. See docs/17-recurring-events.md "Migration" and
//  docs/15-schema-migrations.md "How to add a schema version."
//
//  `KueEvent` gained five new stored properties this phase (`seriesID`,
//  `recurrenceAnchorDate`, `isRecurrenceException`, `isSkipped`, `skippedAt` — see
//  Shared/Models/KueEvent.swift) and a new model, `RecurrenceExclusion`, was added to the
//  schema entirely. Every other model type is unchanged, so — per docs/15-schema-migrations.md
//  step 2 — this schema references them directly from `Shared/Models/`, exactly as
//  `KueSchemaV1` still does; only `KueEvent`'s *old* shape needed its own frozen copy (nested
//  in `KueSchemaV1`, not here — see that file's header for why the nesting had to go on that
//  side rather than this one).
//

import SwiftData

enum KueSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            KueEvent.self,
            RecurrenceExclusion.self,
            KueTask.self,
            KueSchedule.self,
            WidgetConfiguration.self,
            WidgetState.self,
            Template.self,
            UserPreference.self,
        ]
    }
}
