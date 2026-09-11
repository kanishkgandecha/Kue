//
//  KueSchemaV5.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — Template notification defaults. See
//  docs/31-kue-3-notification-studio.md "Template notification defaults" and
//  docs/15-schema-migrations.md "How to add a schema version."
//
//  `Template` gained one new stored property, `notificationRuleDefaultsData` (a JSON-encoded
//  `[NotificationRuleDefault]`, the same pattern `scheduleRulesData` already established —
//  see `NotificationRuleDefault.swift`'s own header for why this is a plain value array, not a
//  new `NotificationRule` relationship). Nothing else in the schema changed shape.
//

import SwiftData
import Foundation

enum KueSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

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
}
