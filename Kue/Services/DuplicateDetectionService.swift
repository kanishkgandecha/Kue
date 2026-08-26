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
    static func findDuplicate(
        title: String,
        startDate: Date,
        timeZoneIdentifier: String,
        excluding excludedID: UUID? = nil,
        in events: [KueEvent]
    ) -> KueEvent? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current

        return events.first { candidate in
            candidate.id != excludedID
                && candidate.status != .archived
                && candidate.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
                && calendar.isDate(candidate.startDate, inSameDayAs: startDate)
        }
    }
}
