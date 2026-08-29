//
//  KueSchemaV3.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. See docs/18-calendar-integration.md
//  "Migration" and docs/15-schema-migrations.md "How to add a schema version."
//
//  `KueEvent` gained five new stored properties this phase — `externalCalendarEventIdentifier`,
//  `externalCalendarIdentifier`, `externalCalendarTitle`, `externalCalendarLastSyncedAt`,
//  `externalCalendarLastKnownModifiedAt` (see Shared/Models/KueEvent.swift) — recording an
//  explicit, user-confirmed link to an Apple Calendar event. No other model type changed and
//  no model was added or removed, so — per docs/15-schema-migrations.md step 2 — this schema
//  references every type directly from `Shared/Models/`, exactly as `KueSchemaV1`/`KueSchemaV2`
//  still do for their own untouched types; only `KueEvent`'s *old* (Phase-3-era) shape needed
//  its own frozen copy, nested in `KueSchemaV2` (see that file's header for why the nesting
//  goes on that side, not this one).
//

import SwiftData
import Foundation

enum KueSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

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
