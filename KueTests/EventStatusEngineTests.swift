//
//  EventStatusEngineTests.swift
//  KueTests
//
//  Covers docs/04-event-types.md "Status transition rules" / "Reconciliation" boundaries —
//  see docs/10-testing-strategy.md "Event engine" for the required cases this maps to.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct EventStatusEngineTests {

    private func makeEvent(
        eventType: EventType = .interview,
        startDate: Date,
        endDate: Date? = nil,
        estimatedDurationMinutes: Int = 60,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = "UTC",
        isCancelled: Bool = false,
        cancelledAt: Date? = nil,
        isManuallyCompleted: Bool = false,
        manuallyCompletedAt: Date? = nil
    ) -> KueEvent {
        KueEvent(
            title: "Test",
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: estimatedDurationMinutes,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            source: .manual,
            isCancelled: isCancelled,
            cancelledAt: cancelledAt,
            isManuallyCompleted: isManuallyCompleted,
            manuallyCompletedAt: manuallyCompletedAt
        )
    }

    // MARK: - Date-driven boundaries

    @Test func moreThanOneDayOutIsUpcoming() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400))
        #expect(EventStatusEngine.derive(for: event, now: now) == .upcoming)
    }

    @Test func exactlyOneCalendarDayOutIsTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9))!
        let event = makeEvent(startDate: start, timeZoneIdentifier: "UTC")
        #expect(EventStatusEngine.derive(for: event, now: now) == .tomorrow)
    }

    @Test func sameCalendarDayBeforeStartTimeIsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let event = makeEvent(startDate: start, timeZoneIdentifier: "UTC")
        #expect(EventStatusEngine.derive(for: event, now: now) == .today)
    }

    @Test func betweenStartAndEffectiveEndIsActive() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60)
        let now = start.addingTimeInterval(30 * 60)
        #expect(EventStatusEngine.derive(for: event, now: now) == .active)
    }

    @Test func afterEffectiveEndIsCompleted() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60)
        let now = start.addingTimeInterval(61 * 60)
        #expect(EventStatusEngine.derive(for: event, now: now) == .completed)
    }

    @Test func zeroDurationEventSkipsActive() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        #expect(EventStatusEngine.derive(for: event, now: start.addingTimeInterval(-1)) == .today)
        #expect(EventStatusEngine.derive(for: event, now: start) == .completed)
    }

    @Test func allDayEventStaysTodayUntilEndOfDayNotStartInstant() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let event = makeEvent(eventType: .deadline, startDate: midnight, isAllDay: true, timeZoneIdentifier: "UTC")

        // Still "today" moments before midnight starts and moments after it starts —
        // an all-day event never becomes .active and doesn't complete at the opening instant.
        #expect(EventStatusEngine.derive(for: event, now: midnight) == .today)
        #expect(EventStatusEngine.derive(for: event, now: midnight.addingTimeInterval(3600)) == .today)
        #expect(EventStatusEngine.derive(for: event, now: midnight.addingTimeInterval(23 * 3600)) == .today)

        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        #expect(EventStatusEngine.derive(for: event, now: nextMidnight) == .completed)
    }

    // MARK: - Cancellation / manual completion

    @Test func cancelledOverridesDates() {
        let event = makeEvent(startDate: .distantFuture, isCancelled: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .cancelled)
    }

    @Test func manuallyCompletedOverridesDates() {
        let event = makeEvent(startDate: .distantFuture, isManuallyCompleted: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .completed)
    }

    @Test func cancellationWinsIfBothFlagsSomehowTrue() {
        let event = makeEvent(startDate: .distantFuture, isCancelled: true, isManuallyCompleted: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .cancelled)
    }

    // MARK: - Timezone behavior

    @Test func statusUsesStoredTimezoneNotDeviceTimezone() {
        // An event pinned to Tokyo, evaluated at an instant that's "tomorrow" in Tokyo but
        // still "today" in UTC. The stored zone must win.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let startInTokyo = tokyo.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9))!
        // 2026-03-10 20:00 UTC == 2026-03-11 05:00 Tokyo — same Tokyo calendar day as start.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 20))!

        let event = makeEvent(startDate: startInTokyo, timeZoneIdentifier: "Asia/Tokyo")
        #expect(EventStatusEngine.derive(for: event, now: now) == .today)
    }

    // MARK: - Reconciliation / archive

    @Test func reconcilePersistsDerivedStatus() {
        let event = makeEvent(startDate: .distantFuture)
        #expect(event.status == .upcoming) // KueEvent's own init default
        let changed = EventStatusEngine.reconcile(event, now: .now)
        #expect(changed == false) // already .upcoming, nothing to change
    }

    @Test func reconcileNeverRevertsArchive() {
        let event = makeEvent(startDate: .distantFuture)
        event.status = .archived
        let changed = EventStatusEngine.reconcile(event, now: .now)
        #expect(changed == false)
        #expect(event.status == .archived)
    }

    @Test func reconcileAutoArchivesAfterWindowPastCompletion() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        let justAfterCompletion = start.addingTimeInterval(60)
        EventStatusEngine.reconcile(event, now: justAfterCompletion)
        #expect(event.status == .completed)

        let wellPastArchiveWindow = start.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        EventStatusEngine.reconcile(event, now: wellPastArchiveWindow)
        #expect(event.status == .archived)
    }

    @Test func reconcileAutoArchivesCancelledEventsFromCancelledAt() {
        let cancelledAt = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: .distantFuture, isCancelled: true, cancelledAt: cancelledAt)
        let wellPast = cancelledAt.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        EventStatusEngine.reconcile(event, now: wellPast)
        #expect(event.status == .archived)
    }

    @Test func sweepUpdatesOnlyNonArchivedEvents() throws {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let stale = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        stale.status = .upcoming // stale — should have completed by "now" below
        let archived = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        archived.status = .archived

        context.insert(stale)
        context.insert(archived)
        try context.save()

        let now = start.addingTimeInterval(3600)
        EventStatusEngine.sweep(context: context, now: now)

        #expect(stale.status == .completed)
        #expect(archived.status == .archived) // untouched
    }
}
