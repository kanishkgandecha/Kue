//
//  WidgetContentServiceTests.swift
//  KueTests
//
//  Covers docs/07-widget-engine.md "Widget instances vs. event eligibility" ("Next Up") and
//  "Widget lifecycle state machine" — the logic the KueWidget extension's TimelineProvider
//  is a thin wrapper over. Requirements 7/8/10: picker/Next-Up filtering, deterministic
//  ordering, and transition dates driving reloads instead of polling.
//

import Testing
import Foundation
@testable import Kue

struct WidgetContentServiceTests {

    private func makeEvent(
        title: String = "Event",
        eventType: EventType = .interview,
        startDate: Date,
        estimatedDurationMinutes: Int = 60,
        isEnabled: Bool = true,
        isCancelled: Bool = false,
        isManuallyCompleted: Bool = false
    ) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            estimatedDurationMinutes: estimatedDurationMinutes,
            timeZoneIdentifier: "UTC",
            source: .manual,
            isCancelled: isCancelled,
            isManuallyCompleted: isManuallyCompleted
        )
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown, isEnabled: isEnabled)
        return event
    }

    // MARK: - "Next Up" (requirement 8)

    @Test func nextUpPicksSoonestEligibleEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let soon = makeEvent(title: "Soon", startDate: now.addingTimeInterval(2 * 86_400))
        let later = makeEvent(title: "Later", startDate: now.addingTimeInterval(10 * 86_400))
        #expect(WidgetContentService.nextUpEvent(from: [later, soon], now: now)?.title == "Soon")
    }

    @Test func nextUpExcludesDisabledEvents() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let disabled = makeEvent(title: "Disabled", startDate: now.addingTimeInterval(86_400), isEnabled: false)
        let enabled = makeEvent(title: "Enabled", startDate: now.addingTimeInterval(10 * 86_400))
        #expect(WidgetContentService.nextUpEvent(from: [disabled, enabled], now: now)?.title == "Enabled")
    }

    @Test func nextUpExcludesCompletedAndCancelledEvents() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let completed = makeEvent(title: "Done", startDate: now.addingTimeInterval(-86_400), estimatedDurationMinutes: 0)
        let cancelled = makeEvent(title: "Cancelled", startDate: now.addingTimeInterval(86_400), isCancelled: true)
        let eligible = makeEvent(title: "Eligible", startDate: now.addingTimeInterval(3 * 86_400))
        #expect(WidgetContentService.nextUpEvent(from: [completed, cancelled, eligible], now: now)?.title == "Eligible")
    }

    @Test func nextUpReturnsNilWhenNothingEligible() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let disabled = makeEvent(startDate: now.addingTimeInterval(86_400), isEnabled: false)
        #expect(WidgetContentService.nextUpEvent(from: [disabled], now: now) == nil)
    }

    @Test func nextUpIsDeterministicOnExactStartDateTies() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let tiedDate = now.addingTimeInterval(5 * 86_400)
        let a = makeEvent(title: "A", startDate: tiedDate)
        let b = makeEvent(title: "B", startDate: tiedDate)
        let first = WidgetContentService.nextUpEvent(from: [a, b], now: now)
        let second = WidgetContentService.nextUpEvent(from: [b, a], now: now) // reversed input order
        #expect(first?.id == second?.id) // same winner regardless of array order
    }

    // MARK: - Lifecycle phase thresholds

    @Test func phaseIsCountdownWhenFarOut() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(20 * 86_400))
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .countdown)
    }

    @Test func phaseIsPreparationAtThreeDaysOut() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(3 * 86_400))
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .preparation)
    }

    @Test func phaseIsPreparationWhenFirstTaskDueEvenBeforeThreeDayThreshold() {
        // "≈3 days out, or when the first KueTask becomes due — whichever is sooner": a task
        // already due (even though the event itself is still 10 days out, well outside the
        // generic 3-day window) must already trigger preparation.
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Prep", dueDate: now.addingTimeInterval(-3600), offsetLabel: "9 days before")
        event.tasks.append(task)
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .preparation)
    }

    @Test func phaseIsTomorrowOneDayOut() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(20 * 3600)) // <1 calendar day but same-ish
        // Use exact calendar-day boundary instead of a raw offset for determinism:
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let event2 = makeEvent(startDate: calendar.date(byAdding: .hour, value: 9, to: tomorrowStart)!)
        _ = event
        #expect(WidgetContentService.currentPhase(for: event2, now: now) == .tomorrow)
    }

    @Test func phaseIsTodayOnEventDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8))!
        let event = makeEvent(startDate: calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 18))!, timeZoneIdentifier: "UTC")
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .today)
    }

    private func makeEvent(startDate: Date, timeZoneIdentifier: String) -> KueEvent {
        let event = makeEvent(startDate: startDate)
        event.timeZoneIdentifier = timeZoneIdentifier
        return event
    }

    @Test func phaseIsCompletedAfterEffectiveEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .completed)
    }

    @Test func phaseIsRemovedWhenArchived() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(86_400))
        event.status = .archived
        #expect(WidgetContentService.currentPhase(for: event, now: now) == .removed)
    }

    // MARK: - Transition plan (requirement 10: precomputed reload dates, not polling)

    @Test func transitionPlanOnlyIncludesFutureBoundariesInAscendingOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(20 * 86_400))
        let plan = WidgetContentService.transitionPlan(for: event, now: now)
        #expect(plan.map(\.date) == plan.map(\.date).sorted())
        #expect(plan.allSatisfy { $0.date > now })
        #expect(plan.last?.phase == .removed) // auto-archive is always the final boundary
        #expect(plan.contains { $0.phase == .completed })
    }

    @Test func transitionPlanIsEmptyForArchivedEvents() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(20 * 86_400))
        event.status = .archived
        #expect(WidgetContentService.transitionPlan(for: event, now: now).isEmpty)
    }

    // MARK: - Display content (rendering)

    @Test func displayContentForTodayIncludesLocation() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(title: "Interview", startDate: now)
        event.location = "HQ"
        let content = WidgetContentService.displayContent(for: event, phase: .today, now: now)
        #expect(content.headline.contains("Interview"))
        #expect(content.subline == "HQ")
    }

    @Test func displayContentForTodayOmitsLocationWhenShowLocationIsOff() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(title: "Interview", startDate: now)
        event.location = "HQ"
        event.widgetConfiguration?.showLocation = false
        let content = WidgetContentService.displayContent(for: event, phase: .today, now: now)
        #expect(content.subline == nil)
    }

    @Test func displayContentForCompletedSaysCompleted() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now)
        let content = WidgetContentService.displayContent(for: event, phase: .completed, now: now)
        #expect(content.subline == "Completed")
    }
}
