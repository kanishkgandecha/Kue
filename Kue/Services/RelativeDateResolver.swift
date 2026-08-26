//
//  RelativeDateResolver.swift
//  Kue
//
//  See docs/06-ai-layer.md "Validation & normalization" step 2 — "rawDateText ... parsed by
//  Kue's own deterministic date-resolution code against the device's calendar and current
//  date at parse time." Pure Foundation, no AI, no FoundationModels import — this is exactly
//  the kind of code the AI layer is never allowed to own (docs/02-architecture.md "the
//  scheduling engine decides... Kue's own date logic" applies equally to parsing).
//
//  Deliberately a small, fixed vocabulary — not a general NL date parser. docs/10-testing-
//  strategy.md's required phrasing styles ("next Friday," "in two weeks," "tomorrow at 3")
//  define the scope; anything outside this vocabulary is correctly reported as unresolved
//  (nil) rather than guessed, which is exactly what turns into an ambiguity banner one layer
//  up (NLDraftNormalizer) instead of a silently wrong date. `NSDataDetector` was considered
//  and rejected — it resolves relative to the live system clock with no way to inject a
//  fixed reference date, which would make this untestable without depending on wall-clock
//  time at test-run time.
//

import Foundation

struct ResolvedDate: Equatable {
    var date: Date
    /// False when the phrase carried no time-of-day (e.g. "the 20th") — the normalizer uses
    /// this to decide `isAllDay`.
    var hasTimeComponent: Bool
}

enum RelativeDateResolver {
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    static func calendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    /// Resolves a start-date phrase (docs' `rawDateText`) against `referenceDate`. `nil`
    /// means "outside the known vocabulary" — an ambiguity, not a guess.
    static func resolve(text: String, referenceDate: Date, timeZoneIdentifier: String) -> ResolvedDate? {
        let calendar = calendar(timeZoneIdentifier: timeZoneIdentifier)
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let (datePart, time) = extractTime(from: normalized, calendar: calendar)

        let day: Date?
        if datePart == "today" {
            day = calendar.startOfDay(for: referenceDate)
        } else if datePart == "tomorrow" {
            day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))
        } else if let match = datePart.wholeMatch(of: /in (\d+) days?/) {
            day = Int(match.1).flatMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: referenceDate)) }
        } else if let match = datePart.wholeMatch(of: /in (\d+) weeks?/) {
            day = Int(match.1).flatMap { calendar.date(byAdding: .day, value: $0 * 7, to: calendar.startOfDay(for: referenceDate)) }
        } else if let match = datePart.wholeMatch(of: /(?:next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)/),
                  let weekday = weekdayNames[String(match.1)] {
            day = nextOccurrence(ofWeekday: weekday, strictlyAfter: referenceDate, calendar: calendar)
        } else if let match = datePart.wholeMatch(of: /the (\d{1,2})(?:st|nd|rd|th)?/), let dayOfMonth = Int(match.1) {
            day = nextOccurrence(ofDayOfMonth: dayOfMonth, strictlyAfter: referenceDate, calendar: calendar)
        } else {
            day = nil
        }

        guard let day else { return nil }

        if let time {
            let combined = calendar.date(
                bySettingHour: time.hour, minute: time.minute, second: 0, of: day
            )
            guard let combined else { return nil }
            return ResolvedDate(date: combined, hasTimeComponent: true)
        }
        return ResolvedDate(date: day, hasTimeComponent: false)
    }

    /// Resolves an end-date/duration phrase (docs' `rawEndDateText`) relative to an already-
    /// resolved `startDate` — `.trip`'s counterpart to `resolve(text:referenceDate:...)`.
    static func resolveEndDate(text: String, startDate: Date, timeZoneIdentifier: String) -> Date? {
        let calendar = calendar(timeZoneIdentifier: timeZoneIdentifier)
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let match = normalized.wholeMatch(of: /for (\d+) days?/), let count = Int(match.1) {
            return calendar.date(byAdding: .day, value: count, to: startDate)
        }
        if let match = normalized.wholeMatch(of: /until (sunday|monday|tuesday|wednesday|thursday|friday|saturday)/),
           let weekday = weekdayNames[String(match.1)] {
            return nextOccurrence(ofWeekday: weekday, strictlyAfter: startDate, calendar: calendar)
        }
        return nil
    }

    // MARK: - Helpers

    /// Splits a trailing " at H(:MM)? (am|pm)?" off the date phrase, e.g.
    /// "next friday at 10" → ("next friday", 10:00).
    private static func extractTime(from text: String, calendar: Calendar) -> (datePart: String, time: (hour: Int, minute: Int)?) {
        guard let match = text.firstMatch(of: /^(.*?)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/) else {
            return (text, nil)
        }
        let datePart = String(match.1).trimmingCharacters(in: .whitespaces)
        var hour = Int(match.2) ?? 0
        let minute = match.3.flatMap { Int($0) } ?? 0
        if let meridiem = match.4 {
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        return (datePart, (hour, minute))
    }

    /// The next date matching `weekday` (1 = Sunday ... 7 = Saturday) strictly after
    /// `referenceDate`'s calendar day — "next Friday" never means today, even if today is
    /// Friday.
    private static func nextOccurrence(ofWeekday weekday: Int, strictlyAfter referenceDate: Date, calendar: Calendar) -> Date? {
        let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
        for offset in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: startOfReferenceDay) else { continue }
            if calendar.component(.weekday, from: candidate) == weekday {
                return candidate
            }
        }
        return nil
    }

    /// The next date whose day-of-month matches `dayOfMonth`, strictly after
    /// `referenceDate`'s calendar day — this month if it hasn't passed yet, otherwise next
    /// month.
    private static func nextOccurrence(ofDayOfMonth dayOfMonth: Int, strictlyAfter referenceDate: Date, calendar: Calendar) -> Date? {
        let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
        var components = calendar.dateComponents([.year, .month], from: startOfReferenceDay)
        components.day = dayOfMonth
        if let thisMonth = calendar.date(from: components), thisMonth > startOfReferenceDay {
            return thisMonth
        }
        guard let nextMonthAnchor = calendar.date(byAdding: .month, value: 1, to: startOfReferenceDay) else { return nil }
        var nextComponents = calendar.dateComponents([.year, .month], from: nextMonthAnchor)
        nextComponents.day = dayOfMonth
        return calendar.date(from: nextComponents)
    }
}
