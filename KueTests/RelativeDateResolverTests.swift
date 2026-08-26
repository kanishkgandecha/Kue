//
//  RelativeDateResolverTests.swift
//  KueTests
//
//  Covers docs/10-testing-strategy.md "At least one case per relative-date phrasing style"
//  at the resolver level (NLDraftNormalizerTests covers the same phrasing again end-to-end
//  through a fixture parser output). A fixed `referenceDate`/timezone makes every case
//  deterministic — no dependence on the day this test happens to run.
//

import Testing
import Foundation
@testable import Kue

struct RelativeDateResolverTests {
    /// Monday, June 2 2025, 09:00 America/New_York.
    private static let referenceDate = makeDate(2025, 6, 2, hour: 9)
    private static let timeZoneIdentifier = "America/New_York"

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func resolve(_ text: String) -> ResolvedDate? {
        RelativeDateResolver.resolve(text: text, referenceDate: Self.referenceDate, timeZoneIdentifier: Self.timeZoneIdentifier)
    }

    @Test func today() {
        let resolved = resolve("today")
        #expect(resolved?.date == Self.makeDate(2025, 6, 2))
        #expect(resolved?.hasTimeComponent == false)
    }

    @Test func tomorrow() {
        let resolved = resolve("tomorrow")
        #expect(resolved?.date == Self.makeDate(2025, 6, 3))
    }

    @Test func inNDays() {
        #expect(resolve("in 2 days")?.date == Self.makeDate(2025, 6, 4))
    }

    @Test func inNWeeks() {
        #expect(resolve("in 2 weeks")?.date == Self.makeDate(2025, 6, 16))
    }

    @Test func nextWeekday() {
        // Monday June 2 -> the next Friday is June 6, whether or not "next" is said.
        #expect(resolve("next friday")?.date == Self.makeDate(2025, 6, 6))
        #expect(resolve("friday")?.date == Self.makeDate(2025, 6, 6))
    }

    @Test func ordinalDayOfMonth() {
        // The 20th hasn't happened yet this month (reference is the 2nd) -> stays in June.
        #expect(resolve("the 20th")?.date == Self.makeDate(2025, 6, 20))
    }

    @Test func ordinalDayOfMonthRollsToNextMonthWhenAlreadyPassed() {
        // The 1st already passed (reference is the 2nd) -> rolls to July.
        #expect(resolve("the 1st")?.date == Self.makeDate(2025, 7, 1))
    }

    @Test func tomorrowAtThree() {
        let resolved = resolve("tomorrow at 3")
        #expect(resolved?.date == Self.makeDate(2025, 6, 3, hour: 3))
        #expect(resolved?.hasTimeComponent == true)
    }

    @Test func nextFridayAtTenWithPM() {
        let resolved = resolve("next friday at 3pm")
        #expect(resolved?.date == Self.makeDate(2025, 6, 6, hour: 15))
    }

    @Test func unrecognizedPhrasingIsUnresolvedNotGuessed() {
        #expect(resolve("sometime soonish") == nil)
    }

    // MARK: - End date (`.trip` counterpart, requires a resolved startDate)

    @Test func endDateForNDays() {
        let start = Self.makeDate(2025, 6, 6)
        let end = RelativeDateResolver.resolveEndDate(text: "for 5 days", startDate: start, timeZoneIdentifier: Self.timeZoneIdentifier)
        #expect(end == Self.makeDate(2025, 6, 11))
    }

    @Test func endDateUntilWeekday() {
        // Friday June 6 -> "until sunday" is June 8.
        let start = Self.makeDate(2025, 6, 6)
        let end = RelativeDateResolver.resolveEndDate(text: "until sunday", startDate: start, timeZoneIdentifier: Self.timeZoneIdentifier)
        #expect(end == Self.makeDate(2025, 6, 8))
    }

    @Test func endDateUnresolvedIsNilNotGuessed() {
        let start = Self.makeDate(2025, 6, 6)
        #expect(RelativeDateResolver.resolveEndDate(text: "eventually", startDate: start, timeZoneIdentifier: Self.timeZoneIdentifier) == nil)
    }

    // MARK: - Timezone pinning (requirement 7)

    @Test func resolutionUsesThePinnedTimezoneNotTheCurrentOne() {
        // Same wall-clock reference instant, resolved against two different pinned zones,
        // must land on the same *local* calendar day in each — proof the resolver uses the
        // zone it's given, not `TimeZone.current` or a hardcoded one.
        let referenceInstant = Self.makeDate(2025, 6, 2, hour: 9) // 09:00 America/New_York
        let tokyoResolved = RelativeDateResolver.resolve(text: "tomorrow", referenceDate: referenceInstant, timeZoneIdentifier: "Asia/Tokyo")
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let expectedTokyoTomorrow = tokyoCalendar.date(byAdding: .day, value: 1, to: tokyoCalendar.startOfDay(for: referenceInstant))
        #expect(tokyoResolved?.date == expectedTokyoTomorrow)
    }
}
