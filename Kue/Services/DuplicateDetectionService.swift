//
//  DuplicateDetectionService.swift
//  Kue
//
//  See docs/04-event-types.md "Duplicate detection (V1 minimum)" — exact title + same
//  calendar day among non-archived events. Fuzzy matching is explicitly out of scope.
//  Pure/testable: takes an already-fetched array rather than owning a fetch, per
//  AGENTS.md "place validation, status calculation, and duplicate detection in
//  independently testable code."
//

import Foundation

enum DuplicateDetectionService {
    /// Returns the first non-archived event with the exact same (trimmed) title on the same
    /// calendar day as `startDate`, if any. `excluding` skips the event being edited so
    /// editing a trip in place doesn't flag itself as its own duplicate.
    ///
    /// `excludingSeriesID` — Kue 2.0 Phase 3, docs/17-recurring-events.md "Duplicate
    /// detection": two occurrences of the *same* recurring series are never flagged against
    /// each other, even if an edit moves one onto the same calendar day as a sibling — they're
    /// legitimately separate occurrences, not an accidental duplicate. A genuinely unrelated
    /// new event (or an occurrence from a *different* series) landing on an existing
    /// occurrence's day is still flagged exactly as before.
    static func findDuplicate(
        title: String,
        startDate: Date,
        timeZoneIdentifier: String,
        excluding excludedID: UUID? = nil,
        excludingSeriesID: UUID? = nil,
        in events: [KueEvent]
    ) -> KueEvent? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current

        return events.first { candidate in
            candidate.id != excludedID
                && candidate.status != .archived
                && !(excludingSeriesID != nil && candidate.seriesID == excludingSeriesID)
                && candidate.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
                && calendar.isDate(candidate.startDate, inSameDayAs: startDate)
        }
    }
}
