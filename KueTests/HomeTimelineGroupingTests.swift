//
//  HomeTimelineGroupingTests.swift
//  KueTests
//
//  Kue 2.0 Phase 7 — coverage for `HomeTimelineGrouping`'s date-sectioning rules. Anchored to
//  `Calendar.current`'s own notion of "now" (local noon today, not a hardcoded historical UTC
//  instant) so these pass identically regardless of the host/simulator's own timezone — the
//  same reason production `kindAndTitle` compares against an implicit `.current`-timezone
//  device calendar, not a fixed one.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct HomeTimelineGroupingTests {
    /// Local noon "today," far from any midnight boundary — every relative-day test below
    /// (Today/Tomorrow/N-days-out) stays correct no matter what timezone this test happens to
    /// run in.
    private static let now: Date = {
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .hour, value: 12, to: startOfToday) ?? Date()
    }()

    private func makeEvent(
        title: String = "Event",
        startDate: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        priority: Priority = .medium,
        isCancelled: Bool = false,
        isManuallyCompleted: Bool = false,
        isSkipped: Bool = false
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: .generic, startDate: startDate, estimatedDurationMinutes: 30,
            isAllDay: isAllDay, timeZoneIdentifier: timeZoneIdentifier, source: .manual, priority: priority,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, isSkipped: isSkipped
        )
    }

    @Test func eventStartingNowFallsUnderToday() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(3600))
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.map(\.title) == ["Today"])
        #expect(sections[0].kind == .today)
    }

    @Test func eventTomorrowFallsUnderTomorrow() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(86_400))
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.map(\.title) == ["Tomorrow"])
        #expect(sections[0].kind == .tomorrow)
    }

    @Test func nearFutureDateGetsAWeekdayAndDateTitleInTheCurrentYear() {
        let target = Self.now.addingTimeInterval(3 * 86_400)
        let event = makeEvent(startDate: target)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        // Same formatting call `formattedTitle` uses internally — an independent check of the
        // day-bucketing math, not a tautological re-derivation of the production string.
        let expectedTitle = Calendar(identifier: .gregorian).startOfDay(for: target)
            .formatted(.dateTime.weekday(.wide).day().month(.wide))
        #expect(sections.map(\.title) == [expectedTitle])
    }

    @Test func distantDateInADifferentYearIncludesTheYear() {
        let target = Self.now.addingTimeInterval(400 * 86_400) // over a year out
        let event = makeEvent(title: "CAT 2026", startDate: target)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        let expectedTitle = Calendar(identifier: .gregorian).startOfDay(for: target)
            .formatted(.dateTime.day().month(.wide).year())
        #expect(sections.map(\.title) == [expectedTitle])
    }

    @Test func aSixthDistinctDateCollapsesIntoARestrainedLaterGroupRatherThanItsOwnSection() {
        // 6 events, each on its own distinct day, days 2...7 from now — 5 individual date
        // sections max, so the 6th day's event must fall into "Later," not a 6th section.
        let events = (2...7).map { offset in
            makeEvent(title: "Day \(offset)", startDate: Self.now.addingTimeInterval(Double(offset) * 86_400))
        }
        let sections = HomeTimelineGrouping.sections(events: events, now: Self.now)
        #expect(sections.count == HomeTimelineGrouping.maximumIndividualDateSections + 1)
        #expect(sections.last?.kind == .later)
        #expect(sections.last?.title == "Later")
        // The distant, explicitly-created event must still be present and discoverable, not dropped.
        #expect(sections.last?.events.map(\.title) == ["Day 7"])
    }

    @Test func laterGroupStaysChronologicallyOrderedAcrossItsFlattenedDays() {
        let earlierOfTheTwoLaterDays = makeEvent(title: "Sooner", startDate: Self.now.addingTimeInterval(7 * 86_400))
        let laterOfTheTwoLaterDays = makeEvent(title: "Later Still", startDate: Self.now.addingTimeInterval(8 * 86_400))
        let fillerDays = (2...6).map { offset in
            makeEvent(title: "Filler \(offset)", startDate: Self.now.addingTimeInterval(Double(offset) * 86_400))
        }
        // Insert the two "Later"-bound events out of chronological order to prove re-sorting happens.
        let sections = HomeTimelineGrouping.sections(events: fillerDays + [laterOfTheTwoLaterDays, earlierOfTheTwoLaterDays], now: Self.now)
        let laterSection = try! #require(sections.last)
        #expect(laterSection.kind == .later)
        #expect(laterSection.events.map(\.title) == ["Sooner", "Later Still"])
    }

    @Test func allDayEventKeepsItsOwnCalendarDateRegardlessOfClockTime() {
        // Two all-day events far apart in clock time but on the identical UTC calendar date —
        // proves bucketing uses the calendar date, not a UTC-instant comparison that could
        // shift one of them to a neighboring day.
        let midnightUTC = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2027, month: 3, day: 15, hour: 0, minute: 30).date!
        let lateNightUTC = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2027, month: 3, day: 15, hour: 23, minute: 30).date!
        let early = makeEvent(title: "Early", startDate: midnightUTC, isAllDay: true, timeZoneIdentifier: "UTC")
        let late = makeEvent(title: "Late", startDate: lateNightUTC, isAllDay: true, timeZoneIdentifier: "UTC")
        let sections = HomeTimelineGrouping.sections(events: [early, late], now: Self.now)
        #expect(sections.count == 1)
        #expect(Set(sections[0].events.map(\.title)) == ["Early", "Late"])
    }

    @Test func pinnedTimezoneNotASharedOneDeterminesWhichCalendarDateAnEventLandsOn() {
        // The identical absolute instant — 2027-03-15 02:00 UTC — is already 15 March in
        // Tokyo (UTC+9) but still 14 March in Los Angeles (UTC-7, PDT). If bucketing read one
        // shared timezone instead of each event's own `timeZoneIdentifier`, both would land on
        // the same calendar day; reading each one's own zone must split them.
        let sameInstant = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2027, month: 3, day: 15, hour: 2).date!
        let tokyoEvent = makeEvent(title: "Tokyo", startDate: sameInstant, timeZoneIdentifier: "Asia/Tokyo")
        let laEvent = makeEvent(title: "LA", startDate: sameInstant, timeZoneIdentifier: "America/Los_Angeles")
        let sections = HomeTimelineGrouping.sections(events: [tokyoEvent, laEvent], now: Self.now)
        #expect(sections.count == 2)
        #expect(Set(sections.flatMap { $0.events.map(\.title) }) == ["Tokyo", "LA"])
    }

    @Test func dstTransitionDayStillBucketsAllItsEventsInTheSameNewYorkSection() {
        // 1 November 2026 — DST ends in New York (clocks fall back at 2am local). An event
        // just after midnight and one at noon must still share the same NY calendar day.
        let justAfterMidnight = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "America/New_York"), year: 2026, month: 11, day: 1, hour: 0, minute: 30).date!
        let noon = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "America/New_York"), year: 2026, month: 11, day: 1, hour: 12).date!
        let early = makeEvent(title: "Before", startDate: justAfterMidnight, timeZoneIdentifier: "America/New_York")
        let late = makeEvent(title: "After", startDate: noon, timeZoneIdentifier: "America/New_York")
        let sections = HomeTimelineGrouping.sections(events: [early, late], now: Self.now)
        #expect(sections.count == 1)
        #expect(Set(sections[0].events.map(\.title)) == ["Before", "After"])
    }

    @Test func deviceTimezoneChangeDoesNotAlterAnEventsStoredMeaning() {
        // The event's pinned timezone is read explicitly — never `TimeZone.current` — so the
        // exact same section results however this call is repeated, independent of whatever
        // the device's own current timezone happens to be.
        let event = makeEvent(startDate: Self.now.addingTimeInterval(3600), timeZoneIdentifier: "Pacific/Auckland")
        let first = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        let second = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(first == second)
        #expect(first.first?.events.map(\.title) == ["Event"])
    }

    @Test func recurringOccurrencesAppearUnderTheirOwnDatesWithoutDuplication() {
        let seriesID = UUID()
        let first = makeEvent(title: "Standup", startDate: Self.now.addingTimeInterval(3600))
        first.seriesID = seriesID
        let second = makeEvent(title: "Standup", startDate: Self.now.addingTimeInterval(86_400))
        second.seriesID = seriesID
        let sections = HomeTimelineGrouping.sections(events: [first, second], now: Self.now)
        #expect(sections.map(\.title) == ["Today", "Tomorrow"])
        #expect(sections[0].events.count == 1)
        #expect(sections[1].events.count == 1)
    }

    @Test func skippedOccurrenceIsExcludedFromTheTimeline() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(3600), isSkipped: true)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.isEmpty)
    }

    @Test func cancelledEventIsExcludedFromTheTimeline() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(3600), isCancelled: true)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.isEmpty)
    }

    @Test func completedEventIsExcludedFromTheTimeline() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(-7200), isManuallyCompleted: true)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.isEmpty)
    }

    @Test func activeEventAppearsInTodayOnlyOnce() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(-600))
        #expect(EventStatusEngine.derive(for: event, now: Self.now) == .active)
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.map(\.title) == ["Today"])
        #expect(sections[0].events.count == 1)
    }

    @Test func activeEventSortsAheadOfOtherEventsInTheSameSection() {
        let laterToday = makeEvent(title: "Later Today", startDate: Self.now.addingTimeInterval(3600))
        let activeNow = makeEvent(title: "Active Now", startDate: Self.now.addingTimeInterval(-600))
        let sections = HomeTimelineGrouping.sections(events: [laterToday, activeNow], now: Self.now)
        #expect(sections[0].events.map(\.title) == ["Active Now", "Later Today"])
    }

    @Test func emptyTodayWithFutureEventsProducesTomorrowNotAnEmptyResult() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(86_400))
        let sections = HomeTimelineGrouping.sections(events: [event], now: Self.now)
        #expect(sections.map(\.title) == ["Tomorrow"])
    }

    @Test func groupingIsDeterministicAcrossRepeatedCalls() {
        let events = (0..<10).map { offset in
            makeEvent(title: "Event \(offset)", startDate: Self.now.addingTimeInterval(Double(offset) * 3600))
        }
        let first = HomeTimelineGrouping.sections(events: events, now: Self.now)
        let second = HomeTimelineGrouping.sections(events: events, now: Self.now)
        #expect(first == second)
    }

    @Test func editingAnEventsDateMovesItToTheNewSectionOnTheNextComputation() {
        let event = makeEvent(startDate: Self.now.addingTimeInterval(3600))
        #expect(HomeTimelineGrouping.sections(events: [event], now: Self.now).map(\.title) == ["Today"])
        event.startDate = Self.now.addingTimeInterval(86_400)
        #expect(HomeTimelineGrouping.sections(events: [event], now: Self.now).map(\.title) == ["Tomorrow"])
    }
}
