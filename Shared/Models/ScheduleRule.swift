//
//  ScheduleRule.swift
//  Kue
//
//  See docs/03-data-model.md "KueSchedule" — the rule representation shared by KueSchedule
//  and Template. A plain Codable struct; SwiftData stores [ScheduleRule] natively, no
//  @Attribute(.transformable) needed.
//

import Foundation

/// `Equatable` added in Kue 2.0 Phase 1 for migration-fixture comparison
/// (KueTests/Migrations/) — a pure Swift-level conformance on a plain value type, not a
/// stored-property change, so it doesn't touch the persisted shape and needs no schema
/// version bump (see docs/15-schema-migrations.md "What counts as a shape change").
struct ScheduleRule: Codable, Equatable {
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
