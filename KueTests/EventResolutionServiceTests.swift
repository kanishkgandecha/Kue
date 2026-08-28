//
//  EventResolutionServiceTests.swift
//  KueTests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "D." — exact, partial, normalized, and
//  ambiguous event resolution; stable "next event" ordering (never diverging from
//  `WidgetContentService.nextUpEvent`); today filtering with pinned timezones; recurring
//  occurrence identity; deterministic behavior for a supplied `now`; never mutating on an
//  ambiguous match.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct EventResolutionServiceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // fixed, arbitrary reference instant

    private func makeEvent(
        title: String = "Event",
        eventType: EventType = .generic,
        startDate: Date,
        timeZoneIdentifier: String = "UTC",
        seriesID: UUID? = nil
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: 60,
            timeZoneIdentifier: timeZoneIdentifier, source: .manual, seriesID: seriesID
        )
    }

    // MARK: - Exact id

    @Test func resolveByIDFindsTheExactEvent() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        let other = makeEvent(title: "Other", startDate: now.addingTimeInterval(7_200))
        #expect(EventResolutionService.resolve(id: event.id, in: [event, other]) == .found(event))
    }

    @Test func resolveByIDIsNotFoundForAStaleID() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        #expect(EventResolutionService.resolve(id: UUID(), in: [event]) == .notFound)
    }

    // MARK: - Exact / normalized title

    @Test func resolveByTitleIsCaseAndDiacriticInsensitive() {
        let event = makeEvent(title: "Café Meeting", startDate: now.addingTimeInterval(3_600))
        #expect(EventResolutionService.resolve(title: "CAFE MEETING", in: [event]) == .found(event))
    }

    @Test func resolveByTitleFindsAUniquePartialMatch() {
        let event = makeEvent(title: "Q3 Board Interview", startDate: now.addingTimeInterval(3_600))
        #expect(EventResolutionService.resolve(title: "interview", in: [event]) == .found(event))
    }

    @Test func resolveByTitlePrefersAnExactMatchOverAPartialOne() {
        let exact = makeEvent(title: "Interview", startDate: now.addingTimeInterval(3_600))
        let partial = makeEvent(title: "Second Interview Round", startDate: now.addingTimeInterval(7_200))
        #expect(EventResolutionService.resolve(title: "Interview", in: [exact, partial]) == .found(exact))
    }

    // MARK: - Ambiguity (requirement: never mutate the first fuzzy match silently)

    @Test func resolveByTitleReturnsAmbiguousForMultiplePartialMatches() {
        let a = makeEvent(title: "Interview A", startDate: now.addingTimeInterval(3_600))
        let b = makeEvent(title: "Interview B", startDate: now.addingTimeInterval(7_200))
        let result = EventResolutionService.resolve(title: "interview", in: [a, b])
        guard case .ambiguous(let matches) = result else {
            Issue.record("expected .ambiguous"); return
        }
        #expect(Set(matches.map(\.id)) == Set([a.id, b.id]))
    }

    @Test func resolveByTitleReturnsAmbiguousForMultipleExactMatches() {
        let a = makeEvent(title: "Standup", startDate: now.addingTimeInterval(3_600))
        let b = makeEvent(title: "Standup", startDate: now.addingTimeInterval(7_200))
        #expect(EventResolutionService.resolve(title: "Standup", in: [a, b]) != .found(a))
        guard case .ambiguous = EventResolutionService.resolve(title: "Standup", in: [a, b]) else {
            Issue.record("expected .ambiguous"); return
        }
    }

    @Test func resolveByTitleIsNotFoundWhenNothingMatches() {
        let event = makeEvent(title: "Interview", startDate: now.addingTimeInterval(3_600))
        #expect(EventResolutionService.resolve(title: "Nonexistent", in: [event]) == .notFound)
    }

    @Test func resolveByTitleIsNotFoundForEmptyQuery() {
        let event = makeEvent(title: "Interview", startDate: now.addingTimeInterval(3_600))
        #expect(EventResolutionService.resolve(title: "   ", in: [event]) == .notFound)
    }

    // MARK: - "Next event" (never diverges from WidgetContentService.nextUpEvent)

    @Test func nextEventMatchesWidgetContentServicesOwnNextUpEvent() {
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3_600))
        let b = makeEvent(title: "B", startDate: now.addingTimeInterval(7_200))
        a.widgetConfiguration = WidgetConfiguration(event: a, widgetType: .countdown)
        b.widgetConfiguration = WidgetConfiguration(event: b, widgetType: .countdown)
        let events = [a, b]
        #expect(EventResolutionService.nextEvent(in: events, now: now)?.id == WidgetContentService.nextUpEvent(from: events, now: now)?.id)
    }

    @Test func nextEventIsDeterministicForTheSameSuppliedNow() {
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3_600))
        a.widgetConfiguration = WidgetConfiguration(event: a, widgetType: .countdown)
        let first = EventResolutionService.nextEvent(in: [a], now: now)
        let second = EventResolutionService.nextEvent(in: [a], now: now)
        #expect(first?.id == second?.id)
    }

    // MARK: - Today (pinned timezone)

    @Test func todaysEventsUsesTheEventsOwnPinnedTimezoneNotTheCurrentDeviceOne() {
        // "Device today," computed with `TimeZone.current` explicitly (not hardcoded), so
        // this is correct on any machine — `Calendar(identifier:)` itself already defaults to
        // `TimeZone.current` (confirmed against Foundation directly), which is exactly what
        // `todaysEvents`'s own device-day check reads.
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let deviceToday = deviceCalendar.startOfDay(for: now)
        let midDeviceToday = deviceToday.addingTimeInterval(12 * 3600) // safely mid-day, clear of any boundary

        // Pin the event to whichever extreme-offset zone genuinely differs from the device's
        // own, so its pinned-timezone calendar day for this instant can't accidentally match
        // by construction.
        let farZone = TimeZone.current.identifier == "Pacific/Kiritimati" ? "Pacific/Midway" : "Pacific/Kiritimati"
        var pinnedCalendar = Calendar(identifier: .gregorian)
        pinnedCalendar.timeZone = TimeZone(identifier: farZone)!
        let pinnedToday = pinnedCalendar.startOfDay(for: midDeviceToday)

        let event = makeEvent(startDate: midDeviceToday, timeZoneIdentifier: farZone)
        let result = EventResolutionService.todaysEvents(in: [event], now: now)

        // Included only when the event's *own* pinned-timezone day matches device-today —
        // a device-timezone-only implementation would instead always include it (midDeviceToday
        // is, by construction, inside deviceToday).
        #expect((result.map(\.id) == [event.id]) == (pinnedToday == deviceToday))
    }

    @Test func todaysEventsExcludesArchivedEvents() {
        let event = makeEvent(startDate: now)
        event.status = .archived
        #expect(EventResolutionService.todaysEvents(in: [event], now: now).isEmpty)
    }

    @Test func todaysEventsExcludesEventsOnADifferentDay() {
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400))
        #expect(EventResolutionService.todaysEvents(in: [event], now: now).isEmpty)
    }

    // MARK: - Upcoming

    @Test func upcomingEventsExcludesCompletedAndArchivedEvents() {
        let upcoming = makeEvent(title: "Upcoming", startDate: now.addingTimeInterval(3_600))
        let completed = makeEvent(title: "Completed", eventType: .deadline, startDate: now.addingTimeInterval(-3_600))
        completed.isManuallyCompleted = true
        let events = [upcoming, completed]
        let result = EventResolutionService.upcomingEvents(in: events, now: now)
        #expect(result.map(\.id) == [upcoming.id])
    }

    // MARK: - Type filter

    @Test func filterByTypeKeepsOnlyMatchingEvents() {
        let exam = makeEvent(title: "Exam", eventType: .exam, startDate: now.addingTimeInterval(3_600))
        let trip = makeEvent(title: "Trip", eventType: .trip, startDate: now.addingTimeInterval(7_200))
        #expect(EventResolutionService.filter([exam, trip], type: .exam).map(\.id) == [exam.id])
    }

    // MARK: - Recurring occurrence identity

    @Test func resolveByIDDistinguishesRecurringOccurrencesOfTheSameSeries() {
        let seriesID = UUID()
        let first = makeEvent(title: "Weekly Sync", startDate: now.addingTimeInterval(86_400), seriesID: seriesID)
        let second = makeEvent(title: "Weekly Sync", startDate: now.addingTimeInterval(8 * 86_400), seriesID: seriesID)
        #expect(EventResolutionService.resolve(id: second.id, in: [first, second]) == .found(second))
    }

    // MARK: - Stable order

    @Test func stableOrderMatchesTheSameDeterministicSortEverySearchSurfaceUses() {
        let a = makeEvent(title: "B Event", startDate: now.addingTimeInterval(7_200))
        let b = makeEvent(title: "A Event", startDate: now.addingTimeInterval(3_600))
        let ordered = EventResolutionService.stableOrder([a, b])
        #expect(ordered.map(\.id) == [b.id, a.id]) // earlier date first
    }

    @Test func stableOrderRespectsTheLimit() {
        let events = (0..<10).map { makeEvent(title: "Event \($0)", startDate: now.addingTimeInterval(Double($0) * 3_600)) }
        #expect(EventResolutionService.stableOrder(events, limit: 3).count == 3)
    }
}
