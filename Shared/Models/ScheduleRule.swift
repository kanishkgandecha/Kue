//
//  ScheduleRule.swift
//  Kue
//
//  See docs/03-data-model.md "KueSchedule" — the rule representation shared by KueSchedule
//  and Template. A plain Codable struct; SwiftData stores [ScheduleRule] natively, no
//  @Attribute(.transformable) needed.
//

import Foundation

struct ScheduleRule: Codable {
    /// e.g. 3 days before startDate.
    var offset: DateComponents
    var taskTitle: String
    /// True for e.g. "1 hour before" style rules — skipped entirely for all-day events.
    var isTimeSensitive: Bool
}

/// docs/03-data-model.md "KueSchedule" — matches an event type, or `.custom`.
enum ScheduleTemplateType: String, Codable, CaseIterable {
    case generic, deadline, exam, interview, trip, custom
}
