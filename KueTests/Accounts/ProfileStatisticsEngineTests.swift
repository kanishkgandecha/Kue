//
//  ProfileStatisticsEngineTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Statistics definitions." Deterministic `now`, plain in-memory
//  `KueEvent`/`KueTask` fixtures — no ModelContext needed since the engine only ever reads
//  values already in memory.
//

import Testing
import Foundation
@testable import Kue

struct ProfileStatisticsEngineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(
        title: String = "Event", eventType: EventType = .generic, startDate: Date,
        isCancelled: Bool = false, isManuallyCompleted: Bool = false, status: EventStatus = .upcoming
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC", source: .manual, status: status,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted
        )
    }

    @Test func emptyDatasetProducesTheEmptyStatisticsValueNotACrash() {
        let statistics = ProfileStatisticsEngine.compute(events: [], now: now)
        #expect(statistics == .empty)
        #expect(statistics.completionRate == nil)
        #expect(statistics.preparationStreak == nil)
        #expect(statistics.nearestUpcomingEvent == nil)
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

    @Test func preparationStreakIsNilWithNoResolvedHistory() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.preparationStreak == nil)
    }

    @Test func preparationStreakCountsConsecutiveCompletionsFromMostRecent() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-2 * 86_400), isManuallyCompleted: true, status: .completed),
            makeEvent(startDate: now.addingTimeInterval(-3 * 86_400), isCancelled: true, status: .cancelled),
            makeEvent(startDate: now.addingTimeInterval(-4 * 86_400), isManuallyCompleted: true, status: .completed),
        ]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.preparationStreak == 2) // stops at the cancelled one, 2 days back
    }

    @Test func preparationStreakIsZeroWhenTheMostRecentResolvedEventWasCancelled() {
        let events = [makeEvent(startDate: now.addingTimeInterval(-1 * 86_400), isCancelled: true, status: .cancelled)]
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now)
        #expect(statistics.preparationStreak == 0)
    }

    @Test func computingTwiceWithTheSameInputsIsDeterministic() {
        let events = [
            makeEvent(startDate: now.addingTimeInterval(3600), status: .upcoming),
            makeEvent(startDate: now.addingTimeInterval(-3600), isManuallyCompleted: true, status: .completed),
        ]
        #expect(ProfileStatisticsEngine.compute(events: events, now: now) == ProfileStatisticsEngine.compute(events: events, now: now))
    }
}
