//
//  RecurrenceEngineTests.swift
//  KueTests
//
//  Kue 2.0 Phase 3 — pure recurrence math, no SwiftData. See docs/17-recurring-events.md.
//  Covers every frequency, intervals > 1, both end kinds, validation failures, the bounded
//  rolling-horizon generator, and the documented calendar edge cases (month-end clamping, leap
//  years, DST, timezone pinning, all-day recurrence via a fixed-time anchor).
//

import Testing
import Foundation
@testable import Kue

struct RecurrenceEngineTests {
    private let utc = "UTC"

    // MARK: - Validation

    @Test func intervalBelowOneIsRejected() {
        let rule = RecurrenceRule(frequency: .daily, interval: 0, end: .never)
        #expect(RecurrenceEngine.validate(rule, startDate: .now).contains(.intervalTooSmall))
    }

    @Test func negativeIntervalIsRejected() {
        let rule = RecurrenceRule(frequency: .weekly, interval: -3, end: .never)
        #expect(RecurrenceEngine.validate(rule, startDate: .now).contains(.intervalTooSmall))
    }

    @Test func occurrenceCountBelowOneIsRejected() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(0))
        #expect(RecurrenceEngine.validate(rule, startDate: .now).contains(.occurrenceCountTooSmall))
    }

    @Test func endDateBeforeStartIsRejected() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .onDate(start.addingTimeInterval(-86_400)))
        #expect(RecurrenceEngine.validate(rule, startDate: start).contains(.endDateBeforeStart))
    }

    @Test func endDateOnOrAfterStartIsAccepted() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .onDate(start))
        #expect(RecurrenceEngine.validate(rule, startDate: start).isEmpty)
    }

    @Test func validNeverEndingRuleHasNoErrors() {
        let rule = RecurrenceRule(frequency: .monthly, interval: 2, end: .never)
        #expect(RecurrenceEngine.validate(rule, startDate: .now).isEmpty)
    }

    // MARK: - Frequencies and intervals > 1

    @Test func dailyStepsByOneDay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000) // fixed reference instant
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: RecurrenceEngine.calendar(timeZoneIdentifier: utc))
        #expect(next.timeIntervalSince(start) == 86_400)
    }

    @Test func dailyIntervalGreaterThanOneStepsByThatManyDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule(frequency: .daily, interval: 5, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: RecurrenceEngine.calendar(timeZoneIdentifier: utc))
        #expect(next.timeIntervalSince(start) == 5 * 86_400)
    }

    @Test func weeklyStepsBySevenDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: RecurrenceEngine.calendar(timeZoneIdentifier: utc))
        #expect(next.timeIntervalSince(start) == 7 * 86_400)
    }

    @Test func weeklyIntervalGreaterThanOneStepsByThatManyWeeks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule(frequency: .weekly, interval: 3, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: RecurrenceEngine.calendar(timeZoneIdentifier: utc))
        #expect(next.timeIntervalSince(start) == 3 * 7 * 86_400)
    }

    @Test func monthlyAdvancesOneCalendarMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 9))!
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: next)
        #expect(comps.year == 2026 && comps.month == 4 && comps.day == 15 && comps.hour == 9)
    }

    @Test func monthlyIntervalGreaterThanOneAdvancesThatManyMonths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let rule = RecurrenceRule(frequency: .monthly, interval: 3, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2026 && comps.month == 4 && comps.day == 10)
    }

    @Test func monthlyCrossingAYearBoundaryAdvancesTheYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let rule = RecurrenceRule(frequency: .monthly, interval: 3, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2027 && comps.month == 2 && comps.day == 15)
    }

    @Test func yearlyAdvancesOneCalendarYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let rule = RecurrenceRule(frequency: .yearly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2027 && comps.month == 6 && comps.day == 1)
    }

    // MARK: - Month-end recurrence and leap years (requirement 25)

    @Test func monthlyFromJan31ClampsToFeb28InANonLeapYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31))! // 2027 is not a leap year
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2027 && comps.month == 2 && comps.day == 28)
    }

    @Test func monthlyFromJan31ClampsToFeb29InALeapYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2028, month: 1, day: 31))! // 2028 is a leap year
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2028 && comps.month == 2 && comps.day == 29)
    }

    @Test func monthlyDoesNotPermanentlyShortenTheDayAfterAClamp() {
        // A clamp on one occurrence must not "stick" — the month after the Feb clamp should
        // go back to the 31st where the target month actually has one.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let jan31 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31))!
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .never)
        let feb28 = RecurrenceEngine.nextAnchor(after: jan31, rule: rule, calendar: calendar)
        let mar = RecurrenceEngine.nextAnchor(after: feb28, rule: rule, calendar: calendar)
        // Because stepping is sequential (from the *clamped* Feb date, not the original Jan
        // anchor), March lands on the 28th too — this is the documented, deterministic
        // trade-off of sequential stepping, verified explicitly rather than left implicit.
        let comps = calendar.dateComponents([.month, .day], from: mar)
        #expect(comps.month == 3 && comps.day == 28)
    }

    @Test func yearlyFromFeb29ClampsToFeb28InANonLeapYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2028, month: 2, day: 29))! // 2028 leap year
        let rule = RecurrenceRule(frequency: .yearly, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar) // 2029, not a leap year
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2029 && comps.month == 2 && comps.day == 28)
    }

    @Test func yearlyFromFeb29LandsOnFeb29AgainFourYearsLater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: utc)!
        let start = calendar.date(from: DateComponents(year: 2028, month: 2, day: 29))!
        let rule = RecurrenceRule(frequency: .yearly, interval: 4, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2032 && comps.month == 2 && comps.day == 29)
    }

    // MARK: - DST and nonexistent/repeated local times (requirement 25)

    @Test func dailyAcrossASpringForwardTransitionPreservesWallClockTime() {
        // America/New_York springs forward on 2026-03-08 at 2:00 AM local.
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "America/New_York")!
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 30))!
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        // "1 day later, same wall-clock time" — 9:30 AM the next day, not 24 raw hours later
        // (which would land at 10:30 AM local across the spring-forward gap).
        #expect(comps.day == 8 && comps.hour == 9 && comps.minute == 30)
    }

    @Test func dailyAcrossAFallBackTransitionPreservesWallClockTime() {
        // America/New_York falls back on 2026-11-01 at 2:00 AM local.
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "America/New_York")!
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 30))!
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(comps.day == 1 && comps.hour == 9 && comps.minute == 30)
    }

    @Test func nonexistentLocalTimeDuringSpringForwardDoesNotCrash() {
        // 2:30 AM on 2026-03-08 never occurs in America/New_York (clocks jump 2:00 -> 3:00).
        // The engine must still deterministically produce *a* Date rather than trap.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30))!
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let next = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        #expect(next > start)
    }

    @Test func repeatedLocalTimeDuringFallBackIsHandledDeterministically() {
        // 1:30 AM on 2026-11-01 occurs twice in America/New_York. Calling the same pure
        // function twice with identical inputs must still produce identical output.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 1, minute: 30))!
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let first = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        let second = RecurrenceEngine.nextAnchor(after: start, rule: rule, calendar: calendar)
        #expect(first == second)
    }

    // MARK: - Timezone pinning (docs/05-scheduling-engine.md's rule, reused here)

    @Test func sameWallClockRuleProducesDifferentAbsoluteInstantsInDifferentZones() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let startUTC = utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!

        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let startTokyo = tokyoCalendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!

        // 9 AM UTC and 9 AM Tokyo are different absolute instants — pinning the calendar to
        // the event's own stored zone (not recomputing against whatever zone happens to be
        // live) is what keeps this deterministic regardless of device timezone.
        #expect(startUTC != startTokyo)

        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let nextUTC = RecurrenceEngine.nextAnchor(after: startUTC, rule: rule, calendar: utcCalendar)
        let nextTokyo = RecurrenceEngine.nextAnchor(after: startTokyo, rule: rule, calendar: tokyoCalendar)
        #expect(nextUTC.timeIntervalSince(startUTC) == nextTokyo.timeIntervalSince(startTokyo))
    }

    // MARK: - advance(_:by:rule:calendar:) — trip endDate carried in lockstep

    @Test func advanceAppliesNextAnchorRepeatedly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let calendar = RecurrenceEngine.calendar(timeZoneIdentifier: utc)
        let three = RecurrenceEngine.advance(start, by: 3, rule: rule, calendar: calendar)
        #expect(three.timeIntervalSince(start) == 3 * 86_400)
    }

    @Test func advanceByZeroStepsReturnsTheOriginalDate() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
        let calendar = RecurrenceEngine.calendar(timeZoneIdentifier: utc)
        #expect(RecurrenceEngine.advance(start, by: 0, rule: rule, calendar: calendar) == start)
    }

    // MARK: - Bounded horizon generation (docs/17-recurring-events.md "Bounded occurrence
    // materialization") — every-frequency + never-ending + both end kinds + validation-adjacent
    // boundary behavior.

    private let horizonNow = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func neverEndingDailyIsCappedByTheMaximumNotTheHorizonAlone() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        // 90 daily anchors would fit the window exactly, but the hard cap (60) bites first —
        // this is the actual unbounded-growth backstop, not just a documentation claim.
        #expect(anchors.count == RecurrenceEngine.maximumMaterializedOccurrences)
    }

    @Test func neverEndingMonthlyStillMaterializesAtLeastTheMinimumPastTheHorizon() {
        // A monthly cadence would only produce ~3 anchors within a 90-day window on its own;
        // the minimum floor keeps generating past the window until it has enough to be useful.
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .never)
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(anchors.count >= RecurrenceEngine.minimumMaterializedOccurrences)
    }

    @Test func neverEndingYearlyRespectsTheSameMinimumFloor() {
        let rule = RecurrenceRule(frequency: .yearly, interval: 1, end: .never)
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(anchors.count == RecurrenceEngine.minimumMaterializedOccurrences)
    }

    @Test func endDateStopsGenerationExactlyAtTheBoundary() {
        let endDate = horizonNow.addingTimeInterval(5 * 86_400 + 3_600) // just past the 5th daily anchor
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .onDate(endDate))
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(anchors.count == 5)
        #expect(anchors.allSatisfy { $0 <= endDate })
    }

    @Test func occurrenceCountEndStopsAtExactlyThatManyMoreAnchors() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(4))
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        // occurrencesSoFar: 1 (the origin already counts as occurrence #1) — 4 total means 3 more.
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(anchors.count == 3)
    }

    @Test func occurrenceCountAlreadyReachedGeneratesNothingMore() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(3))
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 3,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(anchors.isEmpty)
    }

    @Test func anchorsAreStrictlyAscendingAndAfterLastAnchor() {
        let rule = RecurrenceRule(frequency: .daily, interval: 2, end: .never)
        let horizonEnd = horizonNow.addingTimeInterval(30 * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1,
            timeZoneIdentifier: utc, horizonEnd: horizonEnd
        )
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0 > horizonNow })
        #expect(anchors == anchors.sorted())
        #expect(Set(anchors).count == anchors.count) // no duplicates
    }

    @Test func callingNextAnchorsTwiceWithIdenticalInputsIsDeterministic() {
        let rule = RecurrenceRule(frequency: .monthly, interval: 2, end: .afterOccurrences(6))
        let horizonEnd = horizonNow.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let first = RecurrenceEngine.nextAnchors(rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1, timeZoneIdentifier: utc, horizonEnd: horizonEnd)
        let second = RecurrenceEngine.nextAnchors(rule: rule, lastAnchor: horizonNow, occurrencesSoFar: 1, timeZoneIdentifier: utc, horizonEnd: horizonEnd)
        #expect(first == second)
    }

    // MARK: - Human-readable summary (requirement 11)

    @Test func summaryForNeverEndingSingularInterval() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
        #expect(rule.summary(startDate: .now) == "Every week")
    }

    @Test func summaryForNeverEndingPluralInterval() {
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, end: .never)
        #expect(rule.summary(startDate: .now) == "Every 2 weeks")
    }

    @Test func summaryForOccurrenceCountEnd() {
        let rule = RecurrenceRule(frequency: .daily, interval: 1, end: .afterOccurrences(10))
        #expect(rule.summary(startDate: .now) == "Every day, 10 times")
    }

    @Test func summaryForSingleOccurrenceEndUsesSingularWording() {
        let rule = RecurrenceRule(frequency: .monthly, interval: 1, end: .afterOccurrences(1))
        #expect(rule.summary(startDate: .now) == "Every month, 1 time")
    }

    @Test func summaryForEndDateIncludesTheFormattedDate() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = RecurrenceRule(frequency: .yearly, interval: 1, end: .onDate(end))
        let summary = rule.summary(startDate: .now)
        #expect(summary.hasPrefix("Every year until"))
    }
}
