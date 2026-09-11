//
//  Template.swift
//  Kue
//
//  See docs/03-data-model.md "Template" — built-in, versioned preparation-schedule templates
//  per event type. Not a relationship to KueSchedule: schedules are generated FROM a template,
//  they don't hold a live link back to it.
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults":
//  `notificationRuleDefaultsData` follows the exact same JSON-`Data` pattern
//  `scheduleRulesData` already established, for the same reason — see
//  `NotificationRuleDefault.swift`'s own header for why this is a plain value array, not a
//  third relationship on `NotificationRule`.
//

import Foundation
import SwiftData

@Model
final class Template {
    var id: UUID
    var name: String
    var eventType: EventType
    /// See docs/03-data-model.md "KueSchedule" / this file's `KueSchedule.rulesData` —
    /// same array-of-struct-with-DateComponents issue, same JSON-`Data` workaround.
    private var scheduleRulesData: Data
    /// Kue 3.0 Phase 3 — `KueSchemaV5`. Copied into a new event's own `NotificationRule` rows
    /// at creation time (`EventCreationService.create`) — editing this later never touches an
    /// already-created event (docs/31 "Template notification defaults": "deterministic
    /// behavior for later template edits").
    ///
    /// The `= Data()` default literal here is load-bearing, not decorative: this is a genuinely
    /// new, non-optional attribute as of `KueSchemaV5`, and without a schema-level default,
    /// SwiftData's underlying store migration fails outright — "Cannot migrate store in-place:
    /// Validation error missing attribute values on mandatory destination attribute" — *before*
    /// `KueMigrationPlan.migrateV4toV5`'s own `didMigrate` ever runs, found via a real migration
    /// test run. `KueSchemaV2.KueEvent.isRecurrenceException`'s own `= false` literal is the
    /// exact precedent this follows. `didMigrate` still explicitly re-encodes every existing
    /// row's raw bytes to a valid, decodable empty-array JSON payload rather than relying on
    /// `notificationRuleDefaults`'s getter fallback to paper over unencoded `Data()`.
    private var notificationRuleDefaultsData: Data = Data()
    /// Post-V1: always false in V1; user-defined templates are V3 scope.
    var isUserDefined: Bool
    var isBuiltIn: Bool

    var scheduleRules: [ScheduleRule] {
        get { (try? JSONDecoder().decode([ScheduleRule].self, from: scheduleRulesData)) ?? [] }
        set { scheduleRulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var notificationRuleDefaults: [NotificationRuleDefault] {
        get { (try? JSONDecoder().decode([NotificationRuleDefault].self, from: notificationRuleDefaultsData)) ?? [] }
        set { notificationRuleDefaultsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        name: String,
        eventType: EventType,
        scheduleRules: [ScheduleRule] = [],
        notificationRuleDefaults: [NotificationRuleDefault] = [],
        isUserDefined: Bool = false,
        isBuiltIn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.eventType = eventType
        self.scheduleRulesData = (try? JSONEncoder().encode(scheduleRules)) ?? Data()
        self.notificationRuleDefaultsData = (try? JSONEncoder().encode(notificationRuleDefaults)) ?? Data()
        self.isUserDefined = isUserDefined
        self.isBuiltIn = isBuiltIn
    }
}
