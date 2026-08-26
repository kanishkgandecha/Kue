//
//  Template.swift
//  Kue
//
//  See docs/03-data-model.md "Template" — built-in, versioned preparation-schedule templates
//  per event type. Not a relationship to KueSchedule: schedules are generated FROM a template,
//  they don't hold a live link back to it.
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
    /// Post-V1: always false in V1; user-defined templates are V3 scope.
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
