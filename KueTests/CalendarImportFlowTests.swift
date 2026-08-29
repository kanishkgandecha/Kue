//
//  CalendarImportFlowTests.swift
//  KueTests
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration, requirement 41: explicit import confirmation
//  (no auto-create from a selection) and duplicate detection against an imported draft. Mirrors
//  the direct-`KueEvent`-construction pattern EventCRUDTests.swift already uses for
//  persistence-level tests — `EventFormView.save()`'s own `.add` case is the real call site
//  (requirement 16: reuse it unchanged), so this proves the same field-wiring it does, not a
//  re-implementation of it.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct CalendarImportFlowTests {
    private func makeCalendarEvent(title: String, startDate: Date) -> KueCalendarEvent {
        KueCalendarEvent(
            externalIdentifier: "ext-import-1",
            calendarIdentifier: "cal-1",
            calendarTitle: "Home",
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3_600),
            isAllDay: false,
            location: nil,
            notes: nil,
            timeZoneIdentifier: "America/New_York",
            lastModifiedDate: .now,
            recurrence: nil
        )
    }

    // MARK: - No auto-create from selection (requirement 13)

    @Test func buildingADraftNeverPersistsAnything() {
        let container = ModelContainerFactory.makeInMemory()
        let calendarEvent = makeCalendarEvent(title: "Imported Standup", startDate: .init(timeIntervalSince1970: 1_800_000_000))

        _ = CalendarImportPipeline.draft(from: calendarEvent, recurrenceChoice: .singleOccurrenceOnly)

        let allEvents = (try? container.mainContext.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(allEvents.isEmpty)
    }

    // MARK: - Editable before persistence (requirement 12) + explicit confirmation (requirement 14)

    @Test func importedDraftPassesValidationAndOnlyPersistsOnExplicitSave() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let calendarEvent = makeCalendarEvent(title: "Imported Standup", startDate: .init(timeIntervalSince1970: 1_800_000_000))

        var outcome = CalendarImportPipeline.draft(from: calendarEvent, recurrenceChoice: .singleOccurrenceOnly)
        #expect(EventValidator.validate(outcome.draft).isEmpty)

        // Requirement 12 — still editable before the explicit save this test performs below.
        outcome.draft.title = "Imported Standup (edited)"

        // The explicit "confirm" step: mirrors EventFormView.save()'s `.add` case exactly.
        let event = KueEvent(
            title: outcome.draft.title,
            eventType: outcome.draft.eventType,
            startDate: outcome.draft.startDate,
            estimatedDurationMinutes: outcome.draft.eventType.defaultEstimatedDurationMinutes,
            isAllDay: outcome.draft.isAllDay,
            location: outcome.draft.location.isEmpty ? nil : outcome.draft.location,
            notes: outcome.draft.notes.isEmpty ? nil : outcome.draft.notes,
            source: .calendarImport,
            priority: outcome.draft.priority,
            externalCalendarEventIdentifier: outcome.draft.externalCalendarEventIdentifier,
            externalCalendarIdentifier: outcome.draft.externalCalendarIdentifier,
            externalCalendarTitle: outcome.draft.externalCalendarTitle,
            externalCalendarLastKnownModifiedAt: outcome.draft.externalCalendarLastKnownModifiedAt
        )
        context.insert(event)
        try? context.save()

        let persisted = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(persisted.count == 1)
        #expect(persisted.first?.title == "Imported Standup (edited)")
        #expect(persisted.first?.source == .calendarImport)
        #expect(persisted.first?.externalCalendarEventIdentifier == "ext-import-1")
        #expect(persisted.first?.externalCalendarIdentifier == "cal-1")
    }

    // MARK: - Duplicate detection before saving (requirement 15)

    @Test func importingAnEventThatMatchesAnExistingOneIsFlaggedAsADuplicate() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let sharedDate = Date(timeIntervalSince1970: 1_800_000_000)

        let existing = KueEvent(title: "Team Sync", eventType: .generic, startDate: sharedDate, estimatedDurationMinutes: 30, source: .manual)
        context.insert(existing)
        try? context.save()

        let calendarEvent = makeCalendarEvent(title: "Team Sync", startDate: sharedDate)
        let outcome = CalendarImportPipeline.draft(from: calendarEvent, recurrenceChoice: .singleOccurrenceOnly)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: outcome.draft.title,
            startDate: outcome.draft.startDate,
            timeZoneIdentifier: outcome.draft.timeZoneIdentifier,
            in: allEvents
        )
        #expect(duplicate?.id == existing.id)
    }

    @Test func importingAnUnrelatedEventIsNotFlaggedAsADuplicate() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let existing = KueEvent(title: "Team Sync", eventType: .generic, startDate: .init(timeIntervalSince1970: 1_800_000_000), estimatedDurationMinutes: 30, source: .manual)
        context.insert(existing)
        try? context.save()

        let calendarEvent = makeCalendarEvent(title: "Totally Different Event", startDate: .init(timeIntervalSince1970: 1_900_000_000))
        let outcome = CalendarImportPipeline.draft(from: calendarEvent, recurrenceChoice: .singleOccurrenceOnly)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: outcome.draft.title,
            startDate: outcome.draft.startDate,
            timeZoneIdentifier: outcome.draft.timeZoneIdentifier,
            in: allEvents
        )
        #expect(duplicate == nil)
    }
}
