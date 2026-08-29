//
//  WidgetLifecycleTests.swift
//  KueTests
//
//  Phase 5 (M4) — exact-boundary coverage for docs/07-widget-engine.md "Widget lifecycle
//  state machine": all five widget types, the urgent treatment, point-in-time/duration-
//  bearing/trip/all-day completion boundaries, the 3-day auto-archive default, and the
//  reconciliation hooks. WidgetContentServiceTests.swift (Phase 4) covers the phase-
//  threshold basics; this file focuses on exact edges and the pieces Phase 5 adds.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct WidgetLifecycleTests {

    private func makeEvent(
        title: String = "Event",
        eventType: EventType = .interview,
        startDate: Date,
        endDate: Date? = nil,
        estimatedDurationMinutes: Int = 60,
        isAllDay: Bool = false,
        isEnabled: Bool = true,
        widgetType: WidgetType = .countdown
    ) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: estimatedDurationMinutes,
            isAllDay: isAllDay,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: widgetType, isEnabled: isEnabled)
        return event
    }

    // MARK: - All five widget types (requirement 1)

    @Test(arguments: WidgetType.allCases)
    func displayContentCarriesTheEventsConfiguredWidgetType(widgetType: WidgetType) {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), widgetType: widgetType)
        let content = WidgetContentService.displayContent(for: event, phase: .countdown, now: now)
        #expect(content.widgetType == widgetType)
    }

    @Test func progressTypeReflectsTaskCompletionCounts() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), widgetType: .progress)
        let done = KueTask(event: event, title: "Chapter 1", dueDate: now, isCompleted: true, offsetLabel: "10 days before")
        let notDone = KueTask(event: event, title: "Chapter 2", dueDate: now, offsetLabel: "9 days before")
        event.tasks = [done, notDone]

        let content = WidgetContentService.displayContent(for: event, phase: .preparation, now: now)
        #expect(content.tasksCompleted == 1)
        #expect(content.tasksTotal == 2)
    }

    @Test func checklistAndTimelineTypesCarryUpToFourSoonestTasks() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), widgetType: .checklist)
        event.tasks = (0..<6).map { index in
            KueTask(event: event, title: "Task \(index)", dueDate: now.addingTimeInterval(Double(index) * 3600), offsetLabel: "\(index)h before")
        }
        let content = WidgetContentService.displayContent(for: event, phase: .preparation, now: now)
        #expect(content.tasks.count == 4)
        #expect(content.tasks.map(\.title) == ["Task 0", "Task 1", "Task 2", "Task 3"]) // soonest-due first
    }

    // MARK: - Urgent treatment (requirement 3 — never a WidgetType case)

    @Test func interviewAndDeadlineAreUrgentAtTomorrowAndToday() {
        #expect(WidgetContentService.isUrgentTreatment(eventType: .interview, phase: .tomorrow))
        #expect(WidgetContentService.isUrgentTreatment(eventType: .interview, phase: .today))
        #expect(WidgetContentService.isUrgentTreatment(eventType: .deadline, phase: .tomorrow))
        #expect(WidgetContentService.isUrgentTreatment(eventType: .deadline, phase: .today))
    }

    @Test func examAndTripAreNeverUrgent() {
        #expect(WidgetContentService.isUrgentTreatment(eventType: .exam, phase: .tomorrow) == false)
        #expect(WidgetContentService.isUrgentTreatment(eventType: .exam, phase: .today) == false)
        #expect(WidgetContentService.isUrgentTreatment(eventType: .trip, phase: .tomorrow) == false)
        #expect(WidgetContentService.isUrgentTreatment(eventType: .generic, phase: .today) == false)
    }

    @Test func urgentTreatmentNeverAppliesOutsideTomorrowOrToday() {
        #expect(WidgetContentService.isUrgentTreatment(eventType: .interview, phase: .countdown) == false)
        #expect(WidgetContentService.isUrgentTreatment(eventType: .interview, phase: .preparation) == false)
        #expect(WidgetContentService.isUrgentTreatment(eventType: .interview, phase: .completed) == false)
    }

    @Test func urgentNeverAppearsAsAWidgetTypeCase() {
        // Compile-time guarantee, exercised at runtime: there is no `.urgent` case to select.
        #expect(WidgetType.allCases.map(\.rawValue).contains("urgent") == false)
    }

    // MARK: - Completion boundaries (requirement 4; Kue 2.0 Phase 10.1 — docs/25 "F.": passing
    // time lands on Awaiting Outcome, never a silent Completed — only an explicit
    // `isManuallyCompleted` mutation does.

    @Test func pointInTimeZeroDurationEventReachesAwaitingOutcomeExactlyAtStartDate() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        #expect(WidgetContentService.currentPhase(for: event, now: start.addingTimeInterval(-1)) == .today)
        #expect(WidgetContentService.currentPhase(for: event, now: start) == .awaitingOutcome)
    }

    @Test func durationBearingEventStaysTodayThroughItsDurationThenAwaitsOutcome() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .interview, startDate: start, estimatedDurationMinutes: 60)
        #expect(WidgetContentService.currentPhase(for: event, now: start.addingTimeInterval(30 * 60)) == .today)
        #expect(WidgetContentService.currentPhase(for: event, now: start.addingTimeInterval(60 * 60)) == .awaitingOutcome)
    }

    @Test func tripReachesAwaitingOutcomeExactlyAtEndDateNotStartDate() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let end = start.addingTimeInterval(3 * 86_400)
        let event = makeEvent(eventType: .trip, startDate: start, endDate: end, estimatedDurationMinutes: 0)
        #expect(WidgetContentService.currentPhase(for: event, now: start.addingTimeInterval(86_400)) == .today) // mid-trip
        #expect(WidgetContentService.currentPhase(for: event, now: end.addingTimeInterval(-1)) == .today)
        #expect(WidgetContentService.currentPhase(for: event, now: end) == .awaitingOutcome)
    }

    @Test func allDayEventReachesAwaitingOutcomeAtFollowingMidnightNotStartInstant() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let event = makeEvent(eventType: .deadline, startDate: midnight, isAllDay: true)

        #expect(WidgetContentService.currentPhase(for: event, now: midnight) == .today)
        #expect(WidgetContentService.currentPhase(for: event, now: midnight.addingTimeInterval(23 * 3600)) == .today)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        #expect(WidgetContentService.currentPhase(for: event, now: nextMidnight) == .awaitingOutcome)
    }

    // MARK: - Auto-archive at exactly three days (requirement 7; Kue 2.0 Phase 10.1 — docs/25
    // "C.": the 3-day countdown only ever runs from an explicit terminal state)

    @Test func widgetShowsRemovedExactlyAtThreeDayArchiveThresholdAfterManualCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = start
        #expect(EventStatusEngine.autoArchiveDays == 3)

        let threshold = try #require(EventStatusEngine.archiveThreshold(for: event))
        #expect(WidgetContentService.currentPhase(for: event, now: threshold.addingTimeInterval(-1)) == .completed)
        #expect(WidgetContentService.currentPhase(for: event, now: threshold) == .removed)
    }

    @Test func widgetComputesRemovedIndependentlyOfPersistedStatus() {
        // The widget extension never runs the app's sweep — `.removed` must be date-driven,
        // not dependent on `event.status` having already been flipped to `.archived`.
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = start
        #expect(event.status == .upcoming) // never reconciled — still stale

        let wellPastArchive = start.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        #expect(WidgetContentService.currentPhase(for: event, now: wellPastArchive) == .removed)
    }

    @Test func widgetNeverReachesRemovedForAnUnresolvedAwaitingOutcomeEventNoMatterHowMuchTimePasses() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        let wellPastArchive = start.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 30) * 86_400)
        #expect(WidgetContentService.currentPhase(for: event, now: wellPastArchive) == .awaitingOutcome)
    }

    @Test func transitionPlanIncludesRemovedAsTheFinalBoundaryOnlyAfterManualCompletion() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(-5 * 86_400), estimatedDurationMinutes: 0)
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now.addingTimeInterval(-1 * 86_400) // 1 day into the 3-day window
        let plan = WidgetContentService.transitionPlan(for: event, now: now)
        #expect(plan.last?.phase == .removed)
    }

    // MARK: - Next Up exclusions (requirement 8)

    @Test func nextUpExcludesAManuallyArchivedEventEvenIfStillUpcomingByDate() {
        // A user can archive an event directly regardless of its date — `derive(for:)` alone
        // (which ignores `.status`) would otherwise still call this "upcoming".
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.status = .archived
        #expect(WidgetContentService.nextUpEvent(from: [event], now: now) == nil)
    }

    /// Kue 2.0 Phase 3 — a skip reuses `.cancelled` as its derived status (see
    /// EventStatusEngine.derive), so it's excluded from "Next Up" the same way a cancelled
    /// event already is, with no change to `nextUpEvent` itself.
    @Test func nextUpExcludesASkippedOccurrenceEvenIfStillUpcomingByDate() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.isSkipped = true
        #expect(WidgetContentService.nextUpEvent(from: [event], now: now) == nil)
    }

    // MARK: - Reconciliation hooks (requirement 6)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func reconciliationRunRecomputesStaleStatusJustLikeTheUnderlyingSweep() async throws {
        let context = makeContext()
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        event.status = .upcoming // stale
        context.insert(event)
        try context.save()

        let now = start.addingTimeInterval(3600)
        let changed = await EventReconciliation.run(context: context, now: now)

        #expect(changed)
        // Kue 2.0 Phase 10.1 — docs/25 "F.": no explicit outcome yet, so this lands on
        // Awaiting Outcome, not Completed.
        #expect(event.status == .awaitingOutcome)
    }

    @Test func reconciliationRunIsANoOpWhenNothingIsStale() async throws {
        let context = makeContext()
        let event = makeEvent(startDate: .distantFuture)
        context.insert(event)
        try context.save()

        await #expect(EventReconciliation.run(context: context) == false)
    }
}
