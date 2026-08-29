//
//  CalendarImportPipelineTests.swift
//  KueTests
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration, requirement 41: timed-event mapping,
//  all-day-event mapping, multi-day-event mapping, timezone mapping, location/notes, supported
//  recurring-event mapping, unsupported-recurrence fallback. Pure `CalendarImportPipeline`
//  tests — no EventKit, no persistence.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct CalendarImportPipelineTests {
    private func makeEvent(
        title: String = "Fake Event",
        startDate: Date = Date(timeIntervalSince1970: 1_800_000_000),
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        timeZoneIdentifier: String? = "America/New_York",
        recurrence: CalendarRecurrenceInfo? = nil
    ) -> KueCalendarEvent {
        KueCalendarEvent(
            externalIdentifier: "ext-1",
            calendarIdentifier: "cal-1",
            calendarTitle: "Home",
            title: title,
            startDate: startDate,
            endDate: endDate ?? startDate.addingTimeInterval(3_600),
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            timeZoneIdentifier: timeZoneIdentifier,
            lastModifiedDate: Date(timeIntervalSince1970: 1_800_000_000),
            recurrence: recurrence
        )
    }

    // MARK: - Timed-event mapping

    @Test func timedEventMapsToGenericWithMatchingDates() {
        let event = makeEvent(title: "Standup", startDate: .init(timeIntervalSince1970: 1_800_000_000), endDate: .init(timeIntervalSince1970: 1_800_003_600))
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.title == "Standup")
        #expect(outcome.draft.eventType == .generic)
        #expect(outcome.draft.isAllDay == false)
        #expect(outcome.draft.startDate == event.startDate)
    }

    // MARK: - All-day-event mapping (requirement 33: no timezone drift)

    @Test func singleDayAllDayEventMapsToGenericAllDay() {
        let day = Calendar(identifier: .gregorian).startOfDay(for: .init(timeIntervalSince1970: 1_800_000_000))
        let event = makeEvent(startDate: day, endDate: day.addingTimeInterval(86_400), isAllDay: true, timeZoneIdentifier: nil)
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.isAllDay)
        #expect(outcome.draft.eventType == .generic)
        #expect(outcome.draft.startDate == day)
    }

    // MARK: - Multi-day-event mapping (requirement 35)

    @Test func multiDayAllDayEventMapsToTripWithInclusiveEndDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let startDay = calendar.startOfDay(for: .init(timeIntervalSince1970: 1_800_000_000))
        // EventKit's own all-day `endDate` is exclusive — three calendar days is startDay...startDay+3.
        let exclusiveEndDay = calendar.date(byAdding: .day, value: 3, to: startDay)!
        let event = makeEvent(startDate: startDay, endDate: exclusiveEndDay, isAllDay: true, timeZoneIdentifier: nil)

        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.eventType == .trip)
        #expect(outcome.draft.startDate == startDay)
        // The draft's own end date is the last *inclusive* day (two days after start), not the
        // exclusive EventKit boundary.
        #expect(outcome.draft.endDate == calendar.date(byAdding: .day, value: 2, to: startDay))
    }

    @Test func singleDayAllDayEventIsNotTreatedAsMultiDay() {
        let day = Calendar(identifier: .gregorian).startOfDay(for: .init(timeIntervalSince1970: 1_800_000_000))
        let event = makeEvent(startDate: day, endDate: day.addingTimeInterval(86_400), isAllDay: true, timeZoneIdentifier: nil)
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.eventType != .trip)
    }

    // MARK: - Timezone mapping (requirement 34: pinned, not device-reinterpreted)

    @Test func timedEventCarriesForwardItsSourceTimezone() {
        let event = makeEvent(timeZoneIdentifier: "Asia/Tokyo")
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.timeZoneIdentifier == "Asia/Tokyo")
    }

    @Test func allDayEventFallsBackToCurrentTimezoneIdentifierButStaysDateOnly() {
        let day = Calendar(identifier: .gregorian).startOfDay(for: .now)
        let event = makeEvent(startDate: day, endDate: day.addingTimeInterval(86_400), isAllDay: true, timeZoneIdentifier: nil)
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.isAllDay)
        // A timezone identifier is still stored (KueEvent.timeZoneIdentifier is non-optional),
        // but `isAllDay` is what governs date-only semantics everywhere else in the app.
        #expect(!outcome.draft.timeZoneIdentifier.isEmpty)
    }

    // MARK: - Location and notes

    @Test func locationAndNotesAreCarriedForward() {
        let event = makeEvent(location: "123 Main St", notes: "Bring laptop")
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.location == "123 Main St")
        #expect(outcome.draft.notes == "Bring laptop")
    }

    @Test func missingLocationAndNotesMapToEmptyStrings() {
        let event = makeEvent(location: nil, notes: nil)
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.location == "")
        #expect(outcome.draft.notes == "")
    }

    // MARK: - Supported recurring-event mapping (requirement 36)

    @Test func supportedRecurrenceConvertsToSeriesWhenRequested() {
        let recurrence = CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .weekly, interval: 2, end: .never), isFullySupported: true)
        let event = makeEvent(recurrence: recurrence)

        let seriesOutcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .convertToSeries)
        #expect(seriesOutcome.draft.isRecurring)
        #expect(seriesOutcome.draft.recurrenceRule?.frequency == .weekly)
        #expect(seriesOutcome.draft.recurrenceRule?.interval == 2)
        #expect(seriesOutcome.recurrenceLimitationMessage == nil)
    }

    @Test func supportedRecurrenceImportsAsSingleOccurrenceWhenRequested() {
        let recurrence = CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .daily, interval: 1, end: .never), isFullySupported: true)
        let event = makeEvent(recurrence: recurrence)

        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(!outcome.draft.isRecurring)
        #expect(outcome.recurrenceLimitationMessage == nil)
    }

    // MARK: - Unsupported-recurrence fallback (requirement 37)

    @Test func unsupportedRecurrenceNeverConvertsToASeriesEvenIfRequested() {
        let recurrence = CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .weekly, interval: 1, end: .never), isFullySupported: false)
        let event = makeEvent(recurrence: recurrence)

        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .convertToSeries)
        #expect(!outcome.draft.isRecurring)
        #expect(outcome.recurrenceLimitationMessage != nil)
    }

    @Test func nonRecurringEventHasNoLimitationMessage() {
        let outcome = CalendarImportPipeline.draft(from: makeEvent(recurrence: nil), recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.recurrenceLimitationMessage == nil)
        #expect(!outcome.draft.isRecurring)
    }

    // MARK: - Linkage carried through (requirement 20, feeding EventFormView.save())

    @Test func draftCarriesExternalIdentifiersForwardForSaving() {
        let event = makeEvent()
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.externalCalendarEventIdentifier == "ext-1")
        #expect(outcome.draft.externalCalendarIdentifier == "cal-1")
        #expect(outcome.draft.externalCalendarTitle == "Home")
        #expect(outcome.draft.externalCalendarLastKnownModifiedAt == event.lastModifiedDate)
    }
}
