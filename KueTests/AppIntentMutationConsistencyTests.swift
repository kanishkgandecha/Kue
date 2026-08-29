//
//  AppIntentMutationConsistencyTests.swift
//  KueTests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "I." — every mutating path
//  (`EventActions`, `WidgetIntentActions.completeEvent`) must keep Spotlight's copy of the
//  event current: reindexed on every status-changing mutation, removed on delete. These are
//  the exact functions every App Intent in `Kue/AppIntents/`/`KueWidget/` reuses, so this
//  file's coverage is also, transitively, App Intent mutation-consistency coverage — no
//  duplicated assertions against the intents themselves needed.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

// `.eventActionsSyncOutboxSerialized` — see EventActionsSyncOutboxTestLock.swift: every
// `EventActions` call here touches the real, process-global `SystemCloudSyncStateStore.shared`.
@Suite(.eventActionsSyncOutboxSerialized)
@MainActor
struct AppIntentMutationConsistencyTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func insertEvent(in context: ModelContext, startDate: Date) -> KueEvent {
        let event = KueEvent(
            title: "Interview", eventType: .interview, startDate: startDate,
            estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual
        )
        context.insert(event)
        try? context.save()
        return event
    }

    // MARK: - Synchronous mutations (fire-and-forget Spotlight reindex)

    @Test func completeReindexesSpotlightWithTheUpdatedStatus() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(-3_600))
        let indexer = FakeSpotlightIndexer()

        EventActions.complete(event, context: context, now: now, spotlightIndexer: indexer)
        try await Task.sleep(nanoseconds: 50_000_000) // let the fire-and-forget Task run

        #expect(indexer.indexedPayloads[event.id]?.statusLabel == "Completed")
    }

    @Test func cancelReindexesSpotlightWithTheUpdatedStatus() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(3_600))
        let indexer = FakeSpotlightIndexer()

        EventActions.cancel(event, context: context, now: now, spotlightIndexer: indexer)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(indexer.indexedPayloads[event.id]?.statusLabel == "Cancelled")
    }

    @Test func archiveReindexesSpotlightWithTheUpdatedStatus() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(3_600))
        let indexer = FakeSpotlightIndexer()

        EventActions.archive(event, context: context, now: now, spotlightIndexer: indexer)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(indexer.indexedPayloads[event.id]?.statusLabel == "Archived")
    }

    @Test func deleteRemovesTheEventFromSpotlight() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(3_600))
        let eventID = event.id
        let indexer = FakeSpotlightIndexer()
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])

        EventActions.delete(event, context: context, spotlightIndexer: indexer)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(indexer.indexedPayloads[eventID] == nil)
    }

    // MARK: - Async mutations (awaited Spotlight reindex)

    @Test func uncancelReindexesSpotlightWithTheRestoredStatus() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(3_600))
        let indexer = FakeSpotlightIndexer()
        event.isCancelled = true

        await EventActions.uncancel(event, context: context, now: now, spotlightIndexer: indexer)
        #expect(indexer.indexedPayloads[event.id]?.statusLabel != "Cancelled")
    }

    @Test func unarchiveReindexesSpotlightWithTheRestoredStatus() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(3_600))
        event.status = .archived
        let indexer = FakeSpotlightIndexer()

        await EventActions.unarchive(event, context: context, now: now, spotlightIndexer: indexer)
        #expect(indexer.indexedPayloads[event.id]?.statusLabel != "Archived")
    }

    // MARK: - Widget-triggered event completion (WidgetIntentActions)

    @Test func widgetCompleteEventReindexesSpotlight() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(-3_600))
        let indexer = FakeSpotlightIndexer()

        _ = try await WidgetIntentActions.completeEvent(
            eventID: event.id, context: context,
            scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(),
            spotlightIndexer: indexer, now: now
        )
        #expect(indexer.indexedPayloads[event.id]?.statusLabel == "Completed")
    }
}
