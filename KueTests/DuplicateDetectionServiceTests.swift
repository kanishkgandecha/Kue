//
//  DuplicateDetectionServiceTests.swift
//  KueTests
//
//  Covers docs/04-event-types.md "Duplicate detection (V1 minimum)" — exact title + same
//  calendar day, non-archived only.
//

import Testing
import Foundation
@testable import Kue

struct DuplicateDetectionServiceTests {

    private func makeEvent(title: String, startDate: Date, status: EventStatus = .upcoming) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: .generic,
            startDate: startDate,
            estimatedDurationMinutes: 0,
            source: .manual,
            status: status
        )
        return event
    }

    @Test func sameTitleSameDayIsFlagged() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "OS Exam",
            startDate: day.addingTimeInterval(3600), // same day, different time
            timeZoneIdentifier: "UTC",
            in: [existing]
        )
        #expect(duplicate?.id == existing.id)
    }

    @Test func sameTitleDifferentDayIsNotFlagged() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "OS Exam",
            startDate: day.addingTimeInterval(30 * 86_400),
            timeZoneIdentifier: "UTC",
            in: [existing]
        )
        #expect(duplicate == nil)
    }

    @Test func differentTitleSameDayIsNotFlagged() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "Interview",
            startDate: day,
            timeZoneIdentifier: "UTC",
            in: [existing]
        )
        #expect(duplicate == nil)
    }

    @Test func archivedEventsAreNotFlagged() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day, status: .archived)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "OS Exam",
            startDate: day,
            timeZoneIdentifier: "UTC",
            in: [existing]
        )
        #expect(duplicate == nil)
    }

    @Test func excludedEventIsNeverItsOwnDuplicate() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "OS Exam",
            startDate: day,
            timeZoneIdentifier: "UTC",
            excluding: existing.id,
            in: [existing]
        )
        #expect(duplicate == nil)
    }

    // MARK: - Kue 2.0 Phase 3 — recurring series exclusion (docs/17-recurring-events.md
    // "Duplicate detection")

    @Test func sameSeriesOccurrencesAreNeverFlaggedAgainstEachOther() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let seriesID = UUID()
        let sibling = KueEvent(
            title: "Team Sync", eventType: .generic, startDate: day, estimatedDurationMinutes: 0,
            source: .manual, seriesID: seriesID, recurrenceAnchorDate: day
        )
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "Team Sync",
            startDate: day,
            timeZoneIdentifier: "UTC",
            excludingSeriesID: seriesID,
            in: [sibling]
        )
        #expect(duplicate == nil)
    }

    @Test func differentSeriesOnTheSameDayIsStillFlagged() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = KueEvent(
            title: "Team Sync", eventType: .generic, startDate: day, estimatedDurationMinutes: 0,
            source: .manual, seriesID: UUID(), recurrenceAnchorDate: day
        )
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "Team Sync",
            startDate: day,
            timeZoneIdentifier: "UTC",
            excludingSeriesID: UUID(), // a different series than `existing`'s
            in: [existing]
        )
        #expect(duplicate?.id == existing.id)
    }

    @Test func matchIsCaseSensitiveAndWhitespaceTrimmed() {
        let day = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = makeEvent(title: "OS Exam", startDate: day)

        // Trimmed whitespace still matches...
        let trimmedMatch = DuplicateDetectionService.findDuplicate(
            title: "  OS Exam  ", startDate: day, timeZoneIdentifier: "UTC", in: [existing]
        )
        #expect(trimmedMatch?.id == existing.id)

        // ...but a different case is not an "exact" title match.
        let caseMismatch = DuplicateDetectionService.findDuplicate(
            title: "os exam", startDate: day, timeZoneIdentifier: "UTC", in: [existing]
        )
        #expect(caseMismatch == nil)
    }
}
