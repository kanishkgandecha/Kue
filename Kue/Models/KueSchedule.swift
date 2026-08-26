//
//  KueSchedule.swift
//  Kue
//
//  See docs/03-data-model.md "KueSchedule" — the generated (or custom-overridden) rule set
//  that produced an event's tasks. Kept separate from KueTask so the *rule* survives edits
//  or deletions of individual generated tasks.
//

import Foundation
import SwiftData

@Model
final class KueSchedule {
    var id: UUID
    var event: KueEvent?
    var templateType: ScheduleTemplateType
    var rules: [ScheduleRule]
    var isCustom: Bool
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        event: KueEvent? = nil,
        templateType: ScheduleTemplateType,
        rules: [ScheduleRule] = [],
        isCustom: Bool = false,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.event = event
        self.templateType = templateType
        self.rules = rules
        self.isCustom = isCustom
        self.generatedAt = generatedAt
    }
}
