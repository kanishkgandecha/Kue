//
//  MacSharedServiceSmokeTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 — spot-checks proving `Shared/`'s domain logic runs correctly when reached
//  from the `KueMac` module, not a second copy of `KueTests`' own exhaustive coverage of the
//  same pure engines (timeline grouping, search, recurrence, event actions). Compiling a file
//  into two module names doesn't by itself guarantee identical runtime behavior across
//  targets with different build settings (`#if os(...)`, actor-isolation defaults) — these
//  tests are the proof that guarantee actually holds here, one representative case per area.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all four files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    // MARK: - Timeline grouping

    @Test func homeTimelineGroupingSectionsAnUpcomingEventUnderItsOwnDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = MacTestSupport.makeFixtureEvent(startDate: now.addingTimeInterval(3 * 86_400))
        let sections = HomeTimelineGrouping.sections(events: [event], now: now)
        #expect(sections.contains { $0.events.contains { $0.id == event.id } })
    }

    @Test func needsAttentionExcludesAnEventThatHasntEndedYet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = MacTestSupport.makeFixtureEvent(startDate: now.addingTimeInterval(86_400))
        #expect(HomeTimelineGrouping.needsAttentionEvents(events: [event], now: now).isEmpty)
    }

    // MARK: - Search

    @Test func eventListQueryEngineFindsAnEventByTitleSubstring() {
        let event = MacTestSupport.makeFixtureEvent(title: "Quarterly Board Review")
        let results = EventListQueryEngine.query(
            events: [event], searchText: "board", filter: .default, sort: .date
        )
        #expect(results.map(\.id) == [event.id])
    }

    // MARK: - Event actions / lifecycle

    @Test func completingAnEventSetsManualCompletionAndDerivedStatus() async {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent()
        container.mainContext.insert(event)
        try? container.mainContext.save()

        EventActions.complete(event, context: container.mainContext)
        #expect(event.isManuallyCompleted)
        #expect(EventStatusEngine.derive(for: event) == .completed)
        // `EventActions.complete` fires a background `Task` (Live Activity/Spotlight
        // reconciliation, intentionally fire-and-forget for instant UI response — see that
        // function's own header) that keeps running after this function returns; a brief
        // yield here just lets it actually start before `container`/`event` go out of scope,
        // rather than racing teardown. Production behavior is unchanged — this is a test-only
        // accommodation for asynchronous work this same function already doesn't wait for.
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Event creation / editing (via the now-shared `EventSaveService`)

    @Test func eventSaveServiceCreatesAValidatedDraftAsANewEvent() {
        let container = MacTestSupport.makeTestContainer()
        var draft = EventDraft()
        draft.title = "Mac-Created Event"
        draft.eventType = .interview

        let result = EventSaveService.save(draft: draft, mode: .add(source: .manual), context: container.mainContext)
        #expect(result.event.title == "Mac-Created Event")
        #expect(result.event.eventType == .interview)
        let fetched = try? container.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched?.count == 1)
    }

    @Test func eventSaveServiceEditsAPlainEventInPlace() {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent(title: "Before")
        container.mainContext.insert(event)
        try? container.mainContext.save()

        var draft = EventDraft()
        draft.title = "After"
        draft.eventType = event.eventType
        draft.startDate = event.startDate

        _ = EventSaveService.save(draft: draft, mode: .edit(event: event, editScope: .thisOccurrence), context: container.mainContext)
        #expect(event.title == "After")
    }

    // MARK: - Recurrence reconciliation

    @Test func materializingAnInitialSeriesProducesFutureOccurrences() {
        let container = MacTestSupport.makeTestContainer()
        let origin = MacTestSupport.makeFixtureEvent()
        origin.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(4))
        origin.seriesID = UUID()
        origin.recurrenceAnchorDate = origin.startDate
        container.mainContext.insert(origin)

        let materialized = OccurrenceReconciliationService.materializeInitialOccurrences(from: origin, context: container.mainContext)
        #expect(materialized.count > 0)
        #expect(materialized.allSatisfy { $0.seriesID == origin.seriesID })
    }

    // MARK: - Calendar import (Kue 3.0 Phase 1 cleanup) — end-to-end via `FakeCalendarProvider`,
    // never `SystemCalendarProvider`/`EKEventStore`, matching every constraint this round's
    // instructions require.

    @Test func fakeCalendarProviderFetchesTheDeterministicUITestFixture() {
        let provider = FakeCalendarProvider.makeUITestFixture()
        #expect(provider.authorizationState() == .fullAccess)
        let events = provider.fetchEvents(from: .distantPast, to: .distantFuture)
        #expect(events.contains { $0.title == "Fake Calendar Meeting" })
    }

    @Test func calendarImportPipelineAndEventSaveServiceTogetherProduceAPersistedEvent() throws {
        let container = MacTestSupport.makeTestContainer()
        let provider = FakeCalendarProvider.makeUITestFixture()
        let calendarEvent = provider.fetchEvents(from: .distantPast, to: .distantFuture).first { $0.title == "Fake Calendar Meeting" }
        let event = try #require(calendarEvent)

        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(outcome.draft.title == "Fake Calendar Meeting")
        #expect(outcome.draft.externalCalendarEventIdentifier == "fake-ext-meeting")

        // The exact save path `MacEventEditorView`'s `.addFromDraft` mode calls.
        let result = EventSaveService.save(draft: outcome.draft, mode: .add(source: .calendarImport), context: container.mainContext)
        #expect(result.event.source == .calendarImport)
        #expect(result.event.externalCalendarEventIdentifier == "fake-ext-meeting")
        let fetched = try? container.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched?.count == 1)
    }

    @Test func calendarImportPipelineConvertsAFullySupportedRecurrenceOnlyWhenAskedTo() throws {
        let provider = FakeCalendarProvider.makeUITestFixture()
        let weekly = provider.fetchEvents(from: .distantPast, to: .distantFuture).first { $0.title == "Fake Calendar Weekly Sync" }
        let event = try #require(weekly)

        let singleOccurrence = CalendarImportPipeline.draft(from: event, recurrenceChoice: .singleOccurrenceOnly)
        #expect(singleOccurrence.draft.isRecurring == false)

        let series = CalendarImportPipeline.draft(from: event, recurrenceChoice: .convertToSeries)
        #expect(series.draft.isRecurring == true)
    }
}
