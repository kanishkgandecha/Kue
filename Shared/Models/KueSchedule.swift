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
    /// `[ScheduleRule]` doesn't round-trip as a native SwiftData array-of-struct attribute —
    /// `ScheduleRule.offset: DateComponents` crashes Core Data's encoder even for an empty
    /// array. Stored as JSON `Data` instead — this is what "stored as transformable" in
    /// docs/03-data-model.md meant; `rules` below is the public, spec-typed surface.
    private var rulesData: Data
    var isCustom: Bool
    var generatedAt: Date

    var rules: [ScheduleRule] {
        get { (try? JSONDecoder().decode([ScheduleRule].self, from: rulesData)) ?? [] }
        set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

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
        self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        self.isCustom = isCustom
        self.generatedAt = generatedAt
    }
}
