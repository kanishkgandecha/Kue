//
//  TaskSnoozeCalculatorTests.swift
//  KueTests
//
//  See docs/07-widget-engine.md "SnoozeTaskIntent" — the exact clamp contract. Requirement:
//  bounds + unavailable-snooze coverage, pure (no SwiftData, no App Intent).
//

import Testing
import Foundation
@testable import Kue

struct TaskSnoozeCalculatorTests {
    private let timeZoneIdentifier = "America/New_York"
    private let minimumLeadTime = SchedulingEngine.minimumLeadTime // 15 minutes

    private func date(_ secondsSince1970: TimeInterval) -> Date {
        Date(timeIntervalSince1970: secondsSince1970)
    }

    // MARK: - Ordinary case: +1 day, well inside bounds

    @Test func snoozeMovesDueDateForwardByExactlyOneDay() {
        let now = date(1_000_000)
        let dueDate = date(1_000_000 + 3_600) // 1 hour from now
        let eventStart = date(1_000_000 + 30 * 86_400) // a month out — plenty of room
        let result = TaskSnoozeCalculator.snoozedDueDate(
            currentDueDate: dueDate, eventStartDate: eventStart, timeZoneIdentifier: timeZoneIdentifier, now: now
        )
        #expect(result == dueDate.addingTimeInterval(86_400))
    }

    // MARK: - Lower bound (an overdue task snoozed shouldn't land in the past)

    @Test func snoozeIsFlooredToNowPlusMinimumLeadTimeWhenOverdue() {
        let now = date(2_000_000)
        let dueDate = date(2_000_000 - 3 * 86_400) // 3 days overdue
        let eventStart = date(2_000_000 + 30 * 86_400)
        let result = TaskSnoozeCalculator.snoozedDueDate(
            currentDueDate: dueDate, eventStartDate: eventStart, timeZoneIdentifier: timeZoneIdentifier, now: now
        )
        #expect(result == now.addingTimeInterval(minimumLeadTime))
    }

    // MARK: - Upper bound (never push past the event itself)

    @Test func snoozeIsCappedToEventStartMinusMinimumLeadTimeWhenCloseToTheEvent() {
        let now = date(3_000_000)
        // Due date is close enough to the event that +1 day would overshoot it.
        let eventStart = date(3_000_000 + 12 * 3_600) // 12 hours out
        let dueDate = date(3_000_000 + 6 * 3_600) // 6 hours from now, 6 hours before the event
        let result = TaskSnoozeCalculator.snoozedDueDate(
            currentDueDate: dueDate, eventStartDate: eventStart, timeZoneIdentifier: timeZoneIdentifier, now: now
        )
        #expect(result == eventStart.addingTimeInterval(-minimumLeadTime))
    }

    // MARK: - Unavailable (requirement: hidden/rejected when no valid interval remains)

    @Test func snoozeIsUnavailableWhenTheEventIsImminent() {
        let now = date(4_000_000)
        // now + 15min >= eventStart - 15min, i.e. the event is under 30 minutes away.
        let eventStart = date(4_000_000 + 10 * 60)
        let dueDate = date(4_000_000 - 60)
        #expect(TaskSnoozeCalculator.snoozedDueDate(
            currentDueDate: dueDate, eventStartDate: eventStart, timeZoneIdentifier: timeZoneIdentifier, now: now
        ) == nil)
        #expect(!TaskSnoozeCalculator.isSnoozeAvailable(eventStartDate: eventStart, now: now))
    }

    @Test func snoozeIsUnavailableWhenTheEventHasAlreadyPassed() {
        let now = date(5_000_000)
        let eventStart = date(5_000_000 - 3_600) // an hour in the past
        #expect(!TaskSnoozeCalculator.isSnoozeAvailable(eventStartDate: eventStart, now: now))
    }

    @Test func snoozeIsAvailableWithComfortableRoom() {
        let now = date(6_000_000)
        let eventStart = date(6_000_000 + 7 * 86_400)
        #expect(TaskSnoozeCalculator.isSnoozeAvailable(eventStartDate: eventStart, now: now))
    }

    // MARK: - offsetLabel regeneration (not a stale "+1 day" label)

    @Test func offsetLabelReflectsTheActualNewDueDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let eventStart = calendar.date(from: DateComponents(year: 2025, month: 6, day: 10, hour: 9))!
        let newDueDate = calendar.date(byAdding: .day, value: -2, to: eventStart)!
        let label = TaskSnoozeCalculator.offsetLabel(newDueDate: newDueDate, eventStartDate: eventStart, timeZoneIdentifier: timeZoneIdentifier)
        #expect(label == "2 days before")
    }
}
