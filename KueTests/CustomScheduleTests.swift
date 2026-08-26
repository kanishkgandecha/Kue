//
//  CustomScheduleTests.swift
//  KueTests
//
//  Phase 6 (M5 — Templates). Built-in-template correctness is already exhaustively covered
//  by SchedulingEngineTests.swift (Phase 3) — this file covers what Phase 6 actually adds:
//  custom-rule validation, custom-schedule regeneration, and persistence, per
//  docs/05-scheduling-engine.md "Custom schedule validation" / "Custom schedules".
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct CustomScheduleTests {

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    // MARK: - Custom rule validation

    @Test func emptyTaskTitleIsRejected() {
        let errors = SchedulingEngine.validateCustomRule(offset: DateComponents(day: 3), taskTitle: "   ")
        #expect(errors.contains(.taskTitleRequired))
    }

    @Test func offsetBelowMinimumLeadTimeIsRejected() {
        // 5 minutes before is well under the 15-minute floor.
        let errors = SchedulingEngine.validateCustomRule(offset: DateComponents(minute: 5), taskTitle: "Too soon")
        #expect(errors.contains(.offsetTooSmall))
    }

    @Test func offsetAtExactlyMinimumLeadTimeIsAccepted() {
        #expect(SchedulingEngine.isOffsetAboveMinimumLeadTime(DateComponents(minute: 15)))
        #expect(SchedulingEngine.isOffsetAboveMinimumLeadTime(DateComponents(minute: 14)) == false)
    }

    @Test func offsetBeyondMaximumIsRejected() {
        let errors = SchedulingEngine.validateCustomRule(offset: DateComponents(day: 91), taskTitle: "Too far out")
        #expect(errors.contains(.offsetTooLarge))
    }

    @Test func validRuleProducesNoErrors() {
        let errors = SchedulingEngine.validateCustomRule(offset: DateComponents(day: 5), taskTitle: "Remind me")
        #expect(errors.isEmpty)
    }

    @Test func multipleProblemsAreAllReported() {
        // Blank title *and* an offset beyond the maximum — both should surface, not just one.
        let errors = SchedulingEngine.validateCustomRule(offset: DateComponents(day: 200), taskTitle: "")
        #expect(errors.contains(.taskTitleRequired))
        #expect(errors.contains(.offsetTooLarge))
    }

    // MARK: - dueDate(for:startDate:timeZoneIdentifier:)

    @Test func dueDateSubtractsTheOffsetInTheEventsTimezone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!

        let due = try #require(SchedulingEngine.dueDate(for: DateComponents(day: 5), startDate: start, timeZoneIdentifier: "America/New_York"))
        let dueComponents = calendar.dateComponents([.year, .month, .day, .hour], from: due)
        #expect(dueComponents.year == 2026 && dueComponents.month == 6 && dueComponents.day == 10 && dueComponents.hour == 9)
    }

    // MARK: - Custom-schedule regeneration (requirement: "regeneration")

    @Test func regenerateTasksProducesTasksMatchingCustomRulesNotTheBuiltInTemplate() throws {
        let context = makeContext()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = KueEvent(title: "Custom Interview", eventType: .interview, startDate: start, estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)

        let customRules = [
            ScheduleRule(offset: DateComponents(day: 5), taskTitle: "My custom prep", isTimeSensitive: false),
            ScheduleRule(offset: DateComponents(minute: 30), taskTitle: "My custom final check", isTimeSensitive: true),
        ]
        let schedule = KueSchedule(event: event, templateType: .custom, rules: customRules, isCustom: true)
        context.insert(schedule)
        event.schedule = schedule

        let now = Date(timeIntervalSince1970: 1_000_000_000)
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        #expect(event.tasks.count == 2)
        #expect(Set(event.tasks.map(\.title)) == Set(["My custom prep", "My custom final check"]))
        // The built-in interview template's tasks must NOT appear.
        #expect(event.tasks.contains { $0.title == "Preparation start" } == false)
    }

    @Test func customScheduleSurvivesRepeatedRegeneration() throws {
        // Regenerating again (e.g. from an unrelated event edit) must not silently fall back
        // to the built-in template now that isCustom == true.
        let context = makeContext()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = KueEvent(title: "E", eventType: .deadline, startDate: start, estimatedDurationMinutes: 0, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)

        let schedule = KueSchedule(event: event, templateType: .custom, rules: [
            ScheduleRule(offset: DateComponents(day: 10), taskTitle: "Custom-only rule", isTimeSensitive: false),
        ], isCustom: true)
        context.insert(schedule)
        event.schedule = schedule

        let now = Date(timeIntervalSince1970: 1_000_000_000)
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        #expect(event.schedule?.isCustom == true)
        #expect(event.tasks.map(\.title) == ["Custom-only rule"])
    }

    // MARK: - Persistence

    @Test func customScheduleRoundTripsAcrossFetches() throws {
        let context = makeContext()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = KueEvent(title: "Persisted", eventType: .exam, startDate: start, estimatedDurationMinutes: 120, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)

        let schedule = KueSchedule(event: event, templateType: .custom, rules: [
            ScheduleRule(offset: DateComponents(day: 2), taskTitle: "Final cram", isTimeSensitive: false),
        ], isCustom: true)
        context.insert(schedule)
        event.schedule = schedule
        try context.save()

        let fetchedEvents = try context.fetch(FetchDescriptor<KueEvent>())
        let fetched = try #require(fetchedEvents.first)
        #expect(fetched.schedule?.isCustom == true)
        #expect(fetched.schedule?.rules.first?.taskTitle == "Final cram")
        #expect(fetched.schedule?.rules.first?.offset.day == 2)
    }
}
