//
//  SchedulingEngineTests.swift
//  KueTests
//
//  Boundary-focused coverage per docs/10-testing-strategy.md "Scheduling engine" — DST,
//  timezone pinning, short-notice/backward clamp, same-day collisions, edit regeneration,
//  idempotency, all-day skipping, and every V1 type's default template.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct SchedulingEngineTests {

    private func makeEvent(
        eventType: EventType = .interview,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = "UTC"
    ) -> KueEvent {
        KueEvent(
            title: "Test",
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: eventType.defaultEstimatedDurationMinutes,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            source: .manual
        )
    }

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    // MARK: - Built-in templates match docs/05-scheduling-engine.md exactly

    @Test func interviewTemplateMatchesSpec() {
        let rules = SchedulingEngine.defaultRules(for: .interview)
        #expect(rules.map(\.taskTitle) == ["Preparation start", "Technical review", "Project/resume review", "Final reminder"])
        #expect(rules.map { $0.offset.day } == [7, 3, 1, nil])
        #expect(rules.last?.offset.hour == 1)
        #expect(rules.map(\.isTimeSensitive) == [false, false, false, true])
    }

    @Test func examTemplateMatchesSpec() {
        let rules = SchedulingEngine.defaultRules(for: .exam)
        #expect(rules.map(\.taskTitle) == ["Preparation start", "Progress check", "Revision", "Final revision"])
        #expect(rules.map { $0.offset.day } == [14, 7, 3, 1])
        #expect(rules.allSatisfy { !$0.isTimeSensitive })
    }

    @Test func tripTemplateMatchesSpec() {
        let rules = SchedulingEngine.defaultRules(for: .trip)
        #expect(rules.map(\.taskTitle) == ["Countdown start", "Packing", "Departure"])
        #expect(rules.map { $0.offset.day } == [7, 1, nil])
        #expect(rules.last?.offset.hour == 3)
        #expect(rules.map(\.isTimeSensitive) == [false, false, true])
    }

    @Test func deadlineTemplateMatchesSpec() {
        let rules = SchedulingEngine.defaultRules(for: .deadline)
        #expect(rules.map(\.taskTitle) == ["Progress", "Warning", "Urgent"])
        #expect(rules.map { $0.offset.day } == [7, 3, 1])
    }

    @Test func genericTemplateUsesSameGenericCopyAtEveryOffset() {
        let rules = SchedulingEngine.defaultRules(for: .generic)
        #expect(rules.allSatisfy { $0.taskTitle == "Reminder" })
        #expect(rules.map { $0.offset.day } == [7, 3, 1])
    }

    // MARK: - Plan correctness per type (requirement: "each V1 type")

    @Test(arguments: EventType.allCases)
    func planProducesOneTaskPerRuleWhenNothingIsClamped(eventType: EventType) {
        let start = Date(timeIntervalSince1970: 2_000_000_000) // far enough out nothing clamps
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let rules = SchedulingEngine.defaultRules(for: eventType)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: false,
            eventType: eventType, rules: rules, now: now
        )
        #expect(plan.count == rules.count)
        #expect(plan.allSatisfy { !$0.isCompressed })
        // Every due date is strictly before the event itself.
        #expect(plan.allSatisfy { $0.dueDate < start })
    }

    @Test func planIsDeterministic() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let rules = SchedulingEngine.defaultRules(for: .exam)
        let first = SchedulingEngine.plan(startDate: start, timeZoneIdentifier: "UTC", isAllDay: false, eventType: .exam, rules: rules, now: now)
        let second = SchedulingEngine.plan(startDate: start, timeZoneIdentifier: "UTC", isAllDay: false, eventType: .exam, rules: rules, now: now)
        #expect(first == second)
    }

    // MARK: - Backward-scheduling clamp / short notice

    @Test func offsetsThatWouldLandInThePastAreDropped() {
        // Deadline 12 hours out: none of its 7d/3d/1d offsets leave any lead time at all.
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let start = now.addingTimeInterval(12 * 3600)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: false,
            eventType: .deadline, rules: SchedulingEngine.defaultRules(for: .deadline), now: now
        )
        #expect(plan.isEmpty) // never fabricate a task when nothing survives
    }

    @Test func nearestSurvivingOffsetIsCompressedWhenSomeAreDropped() {
        // Interview 2 days out: 7d/3d before are in the past, 1d/1h before survive.
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let start = now.addingTimeInterval(2 * 86_400)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: false,
            eventType: .interview, rules: SchedulingEngine.defaultRules(for: .interview), now: now
        )
        #expect(plan.count == 2)
        #expect(plan[0].isCompressed) // nearest-to-now survivor (the 1d-before slot)
        #expect(plan[0].title.contains("condensed"))
        #expect(plan[1].isCompressed == false)
        #expect(plan[1].title == "Final reminder") // untouched — not the compressed one
    }

    @Test func survivorsMustClearMinimumLeadTimeNotJustBeInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // A due date 5 minutes from now is technically "future" but inside the 15-minute floor.
        let rule = ScheduleRule(offset: DateComponents(minute: 5), taskTitle: "Too soon", isTimeSensitive: true)
        let start = now.addingTimeInterval(10 * 60) // rule's due date = now + 5min
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: false,
            eventType: .generic, rules: [rule], now: now
        )
        #expect(plan.isEmpty)
    }

    // MARK: - Same-day collisions across events (no cross-event awareness)

    @Test func twoEventsGeneratingTasksOnTheSameDayDoNotInterfere() throws {
        let context = makeContext()
        let sharedDay = Date(timeIntervalSince1970: 2_000_000_000)
        let eventA = makeEvent(eventType: .exam, startDate: sharedDay.addingTimeInterval(14 * 86_400))
        let eventB = makeEvent(eventType: .deadline, startDate: sharedDay.addingTimeInterval(7 * 86_400))
        context.insert(eventA)
        context.insert(eventB)

        let now = Date(timeIntervalSince1970: 1_000_000_000)
        SchedulingEngine.regenerateTasks(for: eventA, context: context, now: now)
        SchedulingEngine.regenerateTasks(for: eventB, context: context, now: now)

        #expect(eventA.tasks.count == SchedulingEngine.defaultRules(for: .exam).count)
        #expect(eventB.tasks.count == SchedulingEngine.defaultRules(for: .deadline).count)
    }

    // MARK: - DST

    @Test func offsetPreservesWallClockTimeAcrossSpringForward() throws {
        // America/New_York, 2026: DST starts Sunday March 8 (2:00 AM → 3:00 AM).
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = nyCalendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let now = Date(timeIntervalSince1970: 1_000_000_000) // well before, nothing clamps

        let rule = ScheduleRule(offset: DateComponents(day: 3), taskTitle: "3 days before", isTimeSensitive: false)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "America/New_York", isAllDay: false,
            eventType: .generic, rules: [rule], now: now
        )
        #expect(plan.count == 1)

        let due = try #require(plan.first).dueDate
        let dueComponents = nyCalendar.dateComponents([.year, .month, .day, .hour], from: due)
        // Wall-clock hour stays 9 AM even though the transition happened in between.
        #expect(dueComponents.year == 2026 && dueComponents.month == 3 && dueComponents.day == 7 && dueComponents.hour == 9)
        // Regression check: naive 3×86400-second subtraction would land on a different hour,
        // since one of those three days was only 23 hours long.
        #expect(start.timeIntervalSince(due) != 3 * 86_400)
    }

    @Test func statusAndOffsetMathUseStoredTimezoneNotUTC() throws {
        // A wall-clock 9 AM start in Tokyo, offset "1 day before" — must land on the
        // Tokyo calendar day before, computed in Tokyo's calendar, not UTC's.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let start = tokyo.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        let rule = ScheduleRule(offset: DateComponents(day: 1), taskTitle: "1 day before", isTimeSensitive: false)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "Asia/Tokyo", isAllDay: false,
            eventType: .generic, rules: [rule], now: now
        )
        let due = try #require(plan.first).dueDate
        let dueComponents = tokyo.dateComponents([.year, .month, .day, .hour], from: due)
        #expect(dueComponents.year == 2026 && dueComponents.month == 6 && dueComponents.day == 14 && dueComponents.hour == 9)
    }

    // MARK: - All-day skipping of time-sensitive rules

    @Test func allDayEventSkipsTimeSensitiveRulesEntirely() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let start = now.addingTimeInterval(30 * 86_400)
        let rules = SchedulingEngine.defaultRules(for: .interview) // includes a 1h isTimeSensitive rule
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: true,
            eventType: .interview, rules: rules, now: now
        )
        #expect(plan.count == rules.count - 1) // the "Final reminder" (1h) rule is dropped
        #expect(plan.contains { $0.title == "Final reminder" } == false)
    }

    @Test func timedEventKeepsTimeSensitiveRules() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let start = now.addingTimeInterval(30 * 86_400)
        let rules = SchedulingEngine.defaultRules(for: .interview)
        let plan = SchedulingEngine.plan(
            startDate: start, timeZoneIdentifier: "UTC", isAllDay: false,
            eventType: .interview, rules: rules, now: now
        )
        #expect(plan.count == rules.count)
    }

    // MARK: - Custom schedule / max-offset validation

    @Test func offsetWithinMaximumIsAccepted() {
        #expect(SchedulingEngine.isOffsetWithinMaximum(DateComponents(day: 90)))
        #expect(SchedulingEngine.isOffsetWithinMaximum(DateComponents(day: 30)))
    }

    @Test func offsetBeyondMaximumIsRejected() {
        #expect(SchedulingEngine.isOffsetWithinMaximum(DateComponents(day: 91)) == false)
        #expect(SchedulingEngine.isOffsetWithinMaximum(DateComponents(day: 90, hour: 1)) == false)
    }

    // MARK: - regenerateTasks: edit regeneration, completed-task preservation, atomicity, idempotency

    @Test func regenerateSeedsScheduleAndTasksOnFirstCall() throws {
        let context = makeContext()
        let event = makeEvent(eventType: .exam, startDate: Date(timeIntervalSince1970: 3_000_000_000))
        context.insert(event)

        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let success = SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        #expect(success)
        #expect(event.schedule != nil)
        #expect(event.schedule?.isCustom == false)
        #expect(event.tasks.count == SchedulingEngine.defaultRules(for: .exam).count)
    }

    @Test func regenerateIsIdempotentWhenNothingChanges() throws {
        let context = makeContext()
        let event = makeEvent(eventType: .deadline, startDate: Date(timeIntervalSince1970: 3_000_000_000))
        context.insert(event)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        let firstPass = Set(event.tasks.map { "\($0.title)|\($0.dueDate.timeIntervalSince1970)" })

        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        let secondPass = Set(event.tasks.map { "\($0.title)|\($0.dueDate.timeIntervalSince1970)" })

        #expect(firstPass == secondPass)
        #expect(event.tasks.count == SchedulingEngine.defaultRules(for: .deadline).count) // no duplicate growth
    }

    @Test func regeneratePreservesCompletedTasksAndDropsStaleOnes() throws {
        let context = makeContext()
        let originalStart = Date(timeIntervalSince1970: 3_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: originalStart)
        context.insert(event)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        let taskToComplete = try #require(event.tasks.first)
        let originalDueDate = taskToComplete.dueDate
        taskToComplete.isCompleted = true
        taskToComplete.completedAt = now
        try context.save()

        // Edit the event's start date — per docs/05-scheduling-engine.md, regenerate the
        // full set from the stored rules rather than shifting by a delta.
        event.startDate = originalStart.addingTimeInterval(10 * 86_400)
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        // The completed task survives, untouched, at its ORIGINAL due date.
        #expect(event.tasks.contains { $0.id == taskToComplete.id })
        #expect(taskToComplete.dueDate == originalDueDate)
        #expect(taskToComplete.isCompleted)

        // Every other (non-completed) task reflects the new start date, not the old one.
        let regeneratedDueDates = event.tasks.filter { !$0.isCompleted }.map(\.dueDate)
        #expect(regeneratedDueDates.allSatisfy { $0 > originalDueDate })

        // No duplicate slot for the preserved completed task.
        let keys = event.tasks.map { "\($0.title)|\($0.offsetLabel)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func regenerateAtomicallyLeavesNoPartialStateOnRepeatedCalls() throws {
        let context = makeContext()
        let event = makeEvent(eventType: .trip, startDate: Date(timeIntervalSince1970: 3_000_000_000), endDate: Date(timeIntervalSince1970: 3_100_000_000))
        context.insert(event)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        for _ in 0..<3 {
            SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        }

        let fetchedTasks = try context.fetch(FetchDescriptor<KueTask>())
        #expect(fetchedTasks.count == SchedulingEngine.defaultRules(for: .trip).count)
        #expect(event.tasks.count == fetchedTasks.count)
    }
}
