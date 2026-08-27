//
//  RecurrenceEngine.swift
//  Kue
//
//  See docs/17-recurring-events.md. Pure Foundation, no SwiftData — the recurrence-math
//  counterpart to SchedulingEngine's pure `plan(...)`, independently testable with plain
//  values. Everything that touches `ModelContext` (materializing/replenishing actual `KueEvent`
//  rows) lives in OccurrenceReconciliationService.swift instead, same split
//  SchedulingEngine/EventStatusEngine already establish.
//

import Foundation

enum RecurrenceEngine {
    /// docs/17-recurring-events.md "Bounded occurrence materialization" — the documented
    /// rolling-horizon constants.
    static let horizonWindowDays = 90
    static let minimumMaterializedOccurrences = 3
    static let maximumMaterializedOccurrences = 60

    // MARK: - Validation

    /// Requirements: interval >= 1, occurrence count >= 1, end date not before start.
    /// "End date and occurrence count are mutually exclusive" is a type-level invariant of
    /// `RecurrenceRule.End` (a single-case enum) rather than something validated here — see
    /// that type's own doc comment.
    static func validate(_ rule: RecurrenceRule, startDate: Date) -> [RecurrenceValidationError] {
        var errors: [RecurrenceValidationError] = []
        if rule.interval < 1 { errors.append(.intervalTooSmall) }
        switch rule.end {
        case .never:
            break
        case .onDate(let date):
            if date < startDate { errors.append(.endDateBeforeStart) }
        case .afterOccurrences(let count):
            if count < 1 { errors.append(.occurrenceCountTooSmall) }
        }
        return errors
    }

    static func calendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    // MARK: - Date arithmetic

    /// The next anchor after `date` per `rule.frequency`/`interval`. Daily/weekly step by
    /// calendar day (DST-correct — "the same wall-clock time, N calendar days later," never
    /// raw `TimeInterval` arithmetic, matching docs/05-scheduling-engine.md's own rule).
    /// Monthly/yearly clamp to the last valid day of the target month — a Jan 31 monthly
    /// series lands on Feb 28/29, not "wraps" into March; a Feb 29 yearly series lands on
    /// Feb 28 in a non-leap year.
    static func nextAnchor(after date: Date, rule: RecurrenceRule, calendar: Calendar) -> Date {
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * rule.interval, to: date) ?? date
        case .monthly:
            return addMonthsClamped(rule.interval, to: date, calendar: calendar)
        case .yearly:
            return addMonthsClamped(rule.interval * 12, to: date, calendar: calendar)
        }
    }

    /// `date`, advanced by `steps` applications of `nextAnchor` — used to carry a `.trip`'s
    /// `endDate` (or any other secondary date) forward in lockstep with `startDate`'s own
    /// anchor sequence, so each occurrence's duration is computed the same clamped way its
    /// start was, rather than as a fixed elapsed-seconds offset that could drift across a
    /// month-end clamp.
    static func advance(_ date: Date, by steps: Int, rule: RecurrenceRule, calendar: Calendar) -> Date {
        var result = date
        for _ in 0..<max(steps, 0) {
            result = nextAnchor(after: result, rule: rule, calendar: calendar)
        }
        return result
    }

    private static func addMonthsClamped(_ months: Int, to date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return date }

        let zeroBasedMonth = month - 1 + months
        let yearOffset = zeroBasedMonth >= 0 ? zeroBasedMonth / 12 : (zeroBasedMonth - 11) / 12
        let newMonth = zeroBasedMonth - yearOffset * 12 + 1
        let newYear = year + yearOffset

        components.year = newYear
        components.month = newMonth
        guard let firstOfTargetMonth = calendar.date(from: DateComponents(year: newYear, month: newMonth, day: 1)),
              let daysInTargetMonth = calendar.range(of: .day, in: .month, for: firstOfTargetMonth)?.count
        else { return date }

        components.day = min(day, daysInTargetMonth)
        return calendar.date(from: components) ?? date
    }

    // MARK: - Horizon generation

    /// The deterministic sequence of anchors still to materialize for one series segment,
    /// starting strictly after `lastAnchor` (the most recently existing anchor for this
    /// segment — the origin occurrence counts as the first "existing" one). Stops at the first
    /// of: the rule's own end (`onDate`/`afterOccurrences`), the horizon window (unless fewer
    /// than `minimumCount` future anchors exist for this segment yet), or `maximumCount` new
    /// anchors in this one call — see docs/17-recurring-events.md "Bounded occurrence
    /// materialization" for the rationale behind the constants callers pass.
    ///
    /// `occurrencesSoFar` is 1-based and counts the origin — e.g. a brand-new series calls
    /// this with `lastAnchor: originDate, occurrencesSoFar: 1`.
    ///
    /// `existingFutureCount` is how many occurrences already on the books count toward the
    /// `minimumCount` floor *before* this call generates anything new — e.g. a fresh series
    /// passes `1` (the origin itself); a replenishment pass passes however many of the
    /// segment's already-materialized anchors are still ahead of `now`. Without this, the
    /// floor would only ever look at anchors generated *in this one call*, so a series that
    /// already has plenty of future occurrences would still get `minimumCount` *more* added on
    /// every single replenishment — the bounded-horizon design's whole point is topping up a
    /// shortfall, not padding a floor that's already satisfied.
    static func nextAnchors(
        rule: RecurrenceRule,
        lastAnchor: Date,
        occurrencesSoFar: Int,
        timeZoneIdentifier: String,
        horizonEnd: Date,
        existingFutureCount: Int = 0,
        minimumCount: Int = RecurrenceEngine.minimumMaterializedOccurrences,
        maximumCount: Int = RecurrenceEngine.maximumMaterializedOccurrences
    ) -> [Date] {
        let calendar = calendar(timeZoneIdentifier: timeZoneIdentifier)
        var results: [Date] = []
        var current = lastAnchor
        var index = occurrencesSoFar

        while results.count < maximumCount {
            let candidate = nextAnchor(after: current, rule: rule, calendar: calendar)
            index += 1

            if case .afterOccurrences(let count) = rule.end, index > count { break }
            if case .onDate(let end) = rule.end, candidate > end { break }
            if candidate > horizonEnd && existingFutureCount + results.count >= minimumCount { break }

            results.append(candidate)
            current = candidate
        }
        return results
    }
}
