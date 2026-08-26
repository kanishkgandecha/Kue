//
//  EventValidatorTests.swift
//  KueTests
//
//  Covers docs/13-error-handling.md's "specific message per case" requirement for the
//  manual-entry form, and docs/03-data-model.md's per-type duration defaults.
//

import Testing
import Foundation
@testable import Kue

struct EventValidatorTests {

    @Test(arguments: EventType.allCases)
    func emptyTitleIsRejectedForEveryType(eventType: EventType) {
        var draft = EventDraft()
        draft.eventType = eventType
        draft.title = "   " // whitespace-only counts as empty
        let errors = EventValidator.validate(draft)
        #expect(errors.contains(.titleRequired))
    }

    @Test(arguments: EventType.allCases)
    func validTitleAndDatesPassForEveryType(eventType: EventType) {
        var draft = EventDraft()
        draft.eventType = eventType
        draft.title = "Something"
        draft.startDate = .now
        draft.endDate = .now.addingTimeInterval(86_400)
        #expect(EventValidator.validate(draft).isEmpty)
    }

    @Test func tripEndDateBeforeStartIsRejected() {
        var draft = EventDraft()
        draft.eventType = .trip
        draft.title = "Trip"
        draft.startDate = Date(timeIntervalSince1970: 1_000_000)
        draft.endDate = Date(timeIntervalSince1970: 500_000) // before start
        #expect(EventValidator.validate(draft).contains(.tripEndDateBeforeStart))
    }

    @Test func nonTripTypesIgnoreEndDateOrdering() {
        // A stale/garbage endDate on a non-trip draft must not block creation — it's unused.
        var draft = EventDraft()
        draft.eventType = .generic
        draft.title = "Reminder"
        draft.startDate = Date(timeIntervalSince1970: 1_000_000)
        draft.endDate = Date(timeIntervalSince1970: 1) // "before start", but irrelevant for .generic
        #expect(EventValidator.validate(draft).isEmpty)
    }

    @Test func defaultDurationsMatchDataModelSpec() {
        #expect(EventType.generic.defaultEstimatedDurationMinutes == 0)
        #expect(EventType.deadline.defaultEstimatedDurationMinutes == 0)
        #expect(EventType.exam.defaultEstimatedDurationMinutes == 120)
        #expect(EventType.interview.defaultEstimatedDurationMinutes == 60)
        #expect(EventType.trip.defaultEstimatedDurationMinutes == 0)
    }
}
