//
//  KueSchemaV4.swift
//  Kue
//
//  Kue 3.0 Phase 3 — Notification Studio. See docs/31-kue-3-notification-studio.md "Migration"
//  and docs/15-schema-migrations.md "How to add a schema version."
//
//  Adds one new model, `NotificationRule` (Shared/Models/NotificationRule.swift), and gives
//  `KueEvent`/`KueTask` each a new `@Relationship` to it. Nothing about any *existing* stored
//  property changed shape — this is purely additive, so `.lightweight` is the correct
//  `MigrationStage` (see `KueMigrationPlan.swift`): a brand-new, empty-by-construction
//  relationship needs no data transformation, unlike the V1→V2/V2→V3 stages, which backfilled
//  real values onto already-existing rows.
//
//  "Backfill existing reminder behavior so current users do not unexpectedly lose reminders"
//  (this phase's own requirement) is deliberately **not** a SwiftData data migration at all —
//  there is no existing `NotificationRule` data to backfill, because the table is new. Instead
//  it's a behavioral guarantee `NotificationPlanner` provides structurally: an event/task with
//  zero `NotificationRule` rows (i.e. every event that existed before this phase, and every
//  event created after it that nobody has customized) resolves its notifications entirely from
//  `NotificationGlobalPreferences`, which is itself seeded — the first time it's ever read, on
//  any build that predates this phase — from the exact same `ReminderPreference`/
//  `NotificationIntensity` values that already governed that behavior. See
//  `NotificationGlobalPreferences.swift`'s own header and docs/31 "Migration" for the full
//  reasoning and the test that proves it.
//
//  Kue 3.0 Phase 3 completion pass update — `Template` gained a new stored property
//  (`notificationRuleDefaultsData`, docs/31 "Template notification defaults") as of
//  `KueSchemaV5`, so `Template` is nested here at its pre-existing V4 shape, the same "this
//  type's own shape changed" trigger `KueSchemaV1`'s header documents — **not** a cascade:
//  `Template` has never been relationship-connected to anything (still the same "untouched
//  island" `KueSchemaV2`/`V3`'s own headers already called it), so nothing else in this file
//  needs nesting just because `Template` did. `NotificationRule` itself did not change shape
//  between V4 and V5 (no new `template` relationship was added to it — see
//  `NotificationRuleDefault.swift`'s own header for why), so it's still referenced live here.
//

import SwiftData
import Foundation

enum KueSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

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
            NotificationRule.self,
        ]
    }

    /// Exact copy of `Shared/Models/Template.swift` as it stood before Kue 3.0 Phase 3's
    /// completion pass — see this file's own header. No relationships to nest alongside it;
    /// `Template` was, and remains, an island in this schema's connectivity graph.
    @Model
    final class Template {
        var id: UUID
        var name: String
        var eventType: EventType
        private var scheduleRulesData: Data
        var isUserDefined: Bool
        var isBuiltIn: Bool

        var scheduleRules: [ScheduleRule] {
            get { (try? JSONDecoder().decode([ScheduleRule].self, from: scheduleRulesData)) ?? [] }
            set { scheduleRulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
        }

        init(
            id: UUID = UUID(),
            name: String,
            eventType: EventType,
            scheduleRules: [ScheduleRule] = [],
            isUserDefined: Bool = false,
            isBuiltIn: Bool = true
        ) {
            self.id = id
            self.name = name
            self.eventType = eventType
            self.scheduleRulesData = (try? JSONEncoder().encode(scheduleRules)) ?? Data()
            self.isUserDefined = isUserDefined
            self.isBuiltIn = isBuiltIn
        }
    }
}
