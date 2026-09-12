//
//  ProfileStatisticsEngineTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Statistics definitions." Extended Kue 3.0 Phase 6 — docs/34 "B."
//  audit and "C." new metrics. Deterministic `now`, plain in-memory `KueEvent`/`KueTask`
//  fixtures — no ModelContext needed since the engine only ever reads values already in
//  memory.
//

import Testing
import Foundation
@testable import Kue

struct ProfileStatisticsEngineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(
        title: String = "Event", eventType: EventType = .generic, startDate: Date,
        isCancelled: Bool = false, isSkipped: Bool = false, isManuallyCompleted: Bool = false,
        manuallyCompletedAt: Date? = nil, status: EventStatus = .upcoming
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC", source: .manual, status: status,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted,
            manuallyCompletedAt: manuallyCompletedAt, isSkipped: isSkipped
        )
    }

    @Test func emptyDatasetProducesTheEmptyStatisticsValueNotACrash() {
        let statistics = ProfileStatisticsEngine.compute(events: [], now: now)
        #expect(statistics == .empty)
        #expect(statistics.completionRate == nil)
        #expect(statistics.currentCompletionStreak == nil)
        #expect(statistics.longestCompletionStreak == nil)
        #expect(statistics.averageTaskCompletionLeadTimeHours == nil)
        #expect(statistics.nearestUpcomingEvent == nil)
        #expect(statistics.weeklyActivity.isEmpty)
    }

    @Test func upcomingEventsAreCountedButNotConflatedWithActive() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming),
            makeEvent(startDate: now.addingTimeInterval(7200), status: .tomorrow),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.upcomingEvents == 2)
        #expect(statistics.totalActiveEvents == 2)
    }

    @Test func completedAndCancelledEventsAreExcludedFromActiveAndUpcoming() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-7200), isCancelled: true, status: .cancelled),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.totalActiveEvents == 0)
        #expect(statistics.upcomingEvents == 0)
        #expect(statistics.completedEvents == 1)
    }

    @Test func eventsNeedingReviewAreCountedSeparately() {
        let events = [makeEvent(startDate: now.addingTimeInterval(-3600), status: .awaitingOutcome)]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.eventsNeedingReview == 1)
        #expect(statistics.completedEvents == 0)
    }

    // MARK: Phase 6 — cancelled vs. skipped reported separately

    @Test func cancelledAndSkippedEventsAreCountedInSeparateBuckets() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(-3600), isCancelled: true, status: .cancelled),
            makeEvent(startDate: now.addingTimeInterval(-7200), isSkipped: true, status: .cancelled),
            makeEvent(startDate: now.addingTimeInterval(-10_800), isSkipped: true, status: .cancelled),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.cancelledEvents == 1)
        #expect(statistics.skippedEvents == 2)
    }

    @Test func taskCountsExcludeCancelledEventsExplicitly() {
        let cancelled = makeEvent(startDate: now.addingTimeInterval(3600), isCancelled: true, status: .cancelled)
        cancelled.tasks = [KueTask(event: cancelled, title: "Moot task", dueDate: now, offsetLabel: "now")]
        let active = makeEvent(startDate: now.addingTimeInterval(7200), status: .upcoming)
        let doneTask = KueTask(event: active, title: "Done", dueDate: now, isCompleted: true, offsetLabel: "now")
        let pendingTask = KueTask(event: active, title: "Pending", dueDate: now, offsetLabel: "now")
        active.tasks = [doneTask, pendingTask]

        let statistics = ProfileStatisticsEngine.compute(events: [cancelled, active], now: now)
        #expect(statistics.completedTasks == 1)
        #expect(statistics.pendingTasks == 1)
    }

    @Test func completionRateIsNilWhenThereAreNoRelevantTasks() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.completionRate == nil)
    }

    @Test func completionRateIsComputedWhenTasksExist() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming)
        event.tasks = [
            KueTask(event: event, title: "A", dueDate: now, isCompleted: true, offsetLabel: "now"),
            KueTask(event: event, title: "B", dueDate: now, isCompleted: true, offsetLabel: "now"),
            KueTask(event: event, title: "C", dueDate: now, isCompleted: false, offsetLabel: "now"),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.completionRate == 2.0 / 3.0)
    }

    @Test func countsByEventTypeGroupsEveryEventRegardlessOfStatus() {
        let events = [
            makeEvent(eventType: .exam, startDate: now.addingTimeInterval(3600)),
            makeEvent(eventType: .exam, startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed),
            makeEvent(eventType: .trip, startDate: now.addingTimeInterval(7200)),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.countsByEventType[.exam] == 2)
        #expect(statistics.countsByEventType[.trip] == 1)
    }

    // MARK: Phase 6 — completions grouped by type

    @Test func completedCountsByEventTypeCountsOnlyActuallyCompletedEvents() {
        let events = [
            makeEvent(eventType: .exam, startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed),
            makeEvent(eventType: .exam, startDate: now.addingTimeInterval(3600), status: .upcoming), // not completed
            makeEvent(eventType: .trip, startDate: now.addingTimeInterval(-3600), isCancelled: true, status: .cancelled), // cancelled, not completed
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.completedCountsByEventType[.exam] == 1)
        #expect(statistics.completedCountsByEventType[.trip, default: 0] == 0)
    }

    @Test func nearestUpcomingEventIsTheSoonestNonTerminalFutureEvent() {
        let soon = makeEvent(title: "Soon", startDate: now.addingTimeInterval(3600), status: .upcoming)
        let later = makeEvent(title: "Later", startDate: now.addingTimeInterval(86_400), status: .upcoming)
        let past = makeEvent(title: "Past", startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed)
        let statistics = ProfileStatisticsEngine.compute(events: [later, past, soon], now: now)
        #expect(statistics.nearestUpcomingEvent?.title == "Soon")
    }

    @Test func nearestUpcomingEventExcludesEventsAwaitingReview() {
        let event = makeEvent(startDate: now.addingTimeInterval(-60), status: .awaitingOutcome)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.nearestUpcomingEvent == nil)
    }

    // MARK: Phase 6 — 7/30-day upcoming windows

    @Test func upcomingWindowsCountOnlyNonTerminalEventsWithinEachHorizon() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming), // within both
            makeEvent(startDate: now.addingTimeInterval(5 * 86_400), status: .upcoming), // within 7 and 30
            makeEvent(startDate: now.addingTimeInterval(20 * 86_400), status: .upcoming), // within 30 only
            makeEvent(startDate: now.addingTimeInterval(60 * 86_400), status: .upcoming), // outside both
            makeEvent(startDate: now.addingTimeInterval(3600), isCancelled: true, status: .cancelled), // excluded, terminal
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.upcoming7Days == 2)
        #expect(statistics.upcoming30Days == 3)
    }

    @Test func upcomingWindowIncludesAnEventStartingLaterToday() {
        // Deliberately close to midnight — proves the window uses calendar-day boundaries
        // ("today" counts), not a raw 7*86400-second interval that could exclude it.
        let calendar = Calendar(identifier: .gregorian)
        let event = makeEvent(startDate: now.addingTimeInterval(60), status: .today)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now, calendar: calendar)
        #expect(statistics.upcoming7Days == 1)
    }

    // MARK: Phase 6 — preparation workload

    @Test func preparationWorkloadCountsPendingTasksDueSoonOrOverdue() {
        let event = makeEvent(startDate: now.addingTimeInterval(30 * 86_400), status: .upcoming)
        let dueSoon = KueTask(event: event, title: "Due Soon", dueDate: now.addingTimeInterval(2 * 86_400), offsetLabel: "now")
        let overdue = KueTask(event: event, title: "Overdue", dueDate: now.addingTimeInterval(-86_400), offsetLabel: "now")
        let dueLater = KueTask(event: event, title: "Due Later", dueDate: now.addingTimeInterval(30 * 86_400), offsetLabel: "now")
        event.tasks = [dueSoon, overdue, dueLater]
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.preparationWorkload == 2) // due-soon + overdue, not the far-off one
        #expect(statistics.pendingTasks == 3) // the blanket total still includes all three
    }

    @Test func preparationWorkloadNeverCountsCompletedTasks() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming)
        event.tasks = [KueTask(event: event, title: "Done", dueDate: now, isCompleted: true, completedAt: now, offsetLabel: "now")]
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.preparationWorkload == 0)
    }

    // MARK: Phase 6 — current and longest completion streak

    @Test func streaksAreNilWithNoResolvedHistory() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.currentCompletionStreak == nil)
        #expect(statistics.longestCompletionStreak == nil)
    }

    @Test func currentStreakCountsConsecutiveCompletionsFromMostRecent() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-2 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-3 * 86_400), isCancelled: true, status: .cancelled),
            makeEvent(startDate: now.addingTimeInterval(-4 * 86_400), isManuallyCompleted: true, status: .completed),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.currentCompletionStreak == 2) // stops at the cancelled one, 2 days back
    }

    @Test func currentStreakIsZeroWhenTheMostRecentResolvedEventWasCancelled() {
        let events = [makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isCancelled: true, status: .cancelled)]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.currentCompletionStreak == 0)
    }

    @Test func longestStreakFindsTheBestRunEvenWhenItIsNotTheMostRecentOne() {
        let events = [
            // Most recent: a single completion (current streak = 1).
            makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-2 * 86_400), isCancelled: true, status: .cancelled),
            // An older, longer run of 3 completions.
            makeEvent(startDate: now.addingTimeInterval(-3 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-4 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-5 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-6 * 86_400), isCancelled: true, status: .cancelled),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.currentCompletionStreak == 1)
        #expect(statistics.longestCompletionStreak == 3)
    }

    @Test func skippedEventsBreakAStreakJustLikeCancelledEvents() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isSkipped: true, status: .cancelled),
            makeEvent(startDate: now.addingTimeInterval(-2 * 86_400), isManuallyCompleted: true, status: .completed),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.currentCompletionStreak == 0)
        #expect(statistics.longestCompletionStreak == 1)
    }

    // MARK: Phase 6 — average task completion lead time

    @Test func averageLeadTimeIsNilBelowTheMinimumSampleSize() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), status: .upcoming)
        event.tasks = [
            KueTask(event: event, title: "A", dueDate: now, isCompleted: true, completedAt: now.addingTimeInterval(-3600), offsetLabel: "now"),
            KueTask(event: event, title: "B", dueDate: now, isCompleted: true, completedAt: now.addingTimeInterval(-3600), offsetLabel: "now"),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.averageTaskCompletionLeadTimeHours == nil)
    }

    @Test func averageLeadTimeIsPositiveWhenTasksFinishBeforeTheirDueDate() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), status: .upcoming)
        // Each completed exactly 2 hours before its own due date.
        event.tasks = (0..<3).map { i in
            KueTask(event: event, title: "T\(i)", dueDate: now, isCompleted: true, completedAt: now.addingTimeInterval(-7200), offsetLabel: "now")
        }
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.averageTaskCompletionLeadTimeHours == 2)
    }

    @Test func averageLeadTimeIsNegativeWhenTasksFinishAfterTheirDueDate() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), status: .upcoming)
        event.tasks = (0..<3).map { i in
            KueTask(event: event, title: "T\(i)", dueDate: now.addingTimeInterval(-7200), isCompleted: true, completedAt: now, offsetLabel: "now")
        }
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.averageTaskCompletionLeadTimeHours == -2)
    }

    // MARK: Phase 6 — weekly activity

    @Test func weeklyActivityBucketsCompletionsIntoTheirOwnCalendarWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let event = makeEvent(startDate: now, isManuallyCompleted: true, manuallyCompletedAt: now, status: .completed)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now, calendar: calendar)
        #expect(statistics.weeklyActivity.count == 8) // bounded window
        #expect(statistics.weeklyActivity.last?.completedEventCount == 1) // the current week is the last bucket
        #expect(statistics.weeklyActivity.dropLast().allSatisfy { $0.completedEventCount == 0 })
    }

    @Test func computingTwiceWithTheSameInputsIsDeterministic() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming),
            makeEvent(startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed),
        ]
        #expect(ProfileStatisticsEngine.compute(events: events, now: now) == ProfileStatisticsEngine.compute(events: events, now: now))
    }
}
