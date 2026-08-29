//
//  EventCreationServiceTests.swift
//  KueTests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "A./I." — the shared create path both
//  `EventFormView.save()` and every creating App Intent (`CreateEventIntent`/
//  `QuickAddEventIntent`/`CreateEventFromTemplateIntent`) route through. Covers the write
//  itself, the shared post-write reconciliation (notifications/Live Activity/Spotlight), and
//  that recurrence still materializes correctly from this shared path.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct EventCreationServiceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func createPersistsAllCoreFields() {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Panel Interview"
        draft.startDate = now.addingTimeInterval(3_600)

        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        #expect(event.title == "Panel Interview")
        #expect(event.eventType == .interview)
        #expect(event.source == .shortcuts)
        #expect(event.widgetConfiguration != nil)
    }

    @Test func createRegeneratesTheDefaultPreparationSchedule() {
        let context = makeContext()
        var draft = EventDraft(eventType: .exam)
        draft.title = "Final Exam"
        draft.startDate = now.addingTimeInterval(30 * 86_400)

        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)
        #expect(!event.tasks.isEmpty)
    }

    @Test func createMaterializesARecurringSeriesWhenTheDraftRequestsOne() {
        let context = makeContext()
        var draft = EventDraft(eventType: .generic)
        draft.title = "Weekly Sync"
        draft.startDate = now.addingTimeInterval(86_400)
        draft.isRecurring = true
        draft.recurrenceFrequency = .weekly
        draft.recurrenceInterval = 1
        draft.recurrenceEndKind = .afterCount
        draft.recurrenceOccurrenceCount = 3

        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)
        #expect(event.seriesID != nil)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let seriesMembers = allEvents.filter { $0.seriesID == event.seriesID }
        #expect(seriesMembers.count > 1)
    }

    @Test func reconcileAfterWriteIndexesTheNewEventInSpotlight() async {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Panel Interview"
        draft.startDate = now.addingTimeInterval(3_600)
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        let spotlightIndexer = FakeSpotlightIndexer()
        let liveActivityManager = FakeLiveActivityManager()
        await EventCreationService.reconcileAfterWrite(
            event, context: context, now: now,
            liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer
        )

        #expect(spotlightIndexer.indexedPayloads[event.id]?.title == "Panel Interview")
    }

    @Test func reconcileAfterWriteIsANoOpForLiveActivityWhenNothingIsFocused() async {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Unrelated Event"
        draft.startDate = now.addingTimeInterval(3_600)
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        let liveActivityManager = FakeLiveActivityManager()
        await EventCreationService.reconcileAfterWrite(
            event, context: context, now: now,
            liveActivityManager: liveActivityManager, spotlightIndexer: FakeSpotlightIndexer()
        )
        // Nothing was ever focused — creating an unrelated event must never start/select one.
        #expect(liveActivityManager.runningEventID == nil)
    }
}
