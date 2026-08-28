//
//  SpotlightIndexingTests.swift
//  KueTests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "G." — Spotlight item generation,
//  privacy redaction (only title/type/date/status — never notes/location), incremental
//  indexing/deletion, and full reconciliation. All through `FakeSpotlightIndexer` — no real
//  Core Spotlight call anywhere in this file.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct SpotlightIndexingTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func makeEvent(
        title: String = "Interview",
        eventType: EventType = .interview,
        startDate: Date,
        notes: String? = "private notes",
        location: String? = "123 Secret St",
        isCancelled: Bool = false,
        isManuallyCompleted: Bool = false
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC", location: location, notes: notes, source: .manual,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted
        )
    }

    // MARK: - Payload generation / privacy redaction

    @Test func payloadIncludesOnlyThePrivacySafeFieldList() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let payload = SpotlightEventPayloadBuilder.payload(for: event, now: now)
        #expect(payload.eventID == event.id)
        #expect(payload.title == "Interview")
        #expect(payload.eventTypeDisplayName == "Interview")
        #expect(payload.effectiveDate == event.startDate)
        #expect(payload.statusLabel == "Upcoming")
        // Requirement: notes/location are never part of the indexed payload struct at all —
        // there is no field on `SpotlightEventPayload` that could carry them.
    }

    @Test func payloadStatusLabelReflectsCompletedState() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3_600), isManuallyCompleted: true)
        let payload = SpotlightEventPayloadBuilder.payload(for: event, now: now)
        #expect(payload.statusLabel == "Completed")
    }

    @Test func payloadStatusLabelReflectsCancelledState() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600), isCancelled: true)
        let payload = SpotlightEventPayloadBuilder.payload(for: event, now: now)
        #expect(payload.statusLabel == "Cancelled")
    }

    @Test func payloadStatusLabelReflectsArchivedStateEvenWhenDateWiseStillUpcoming() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        event.status = .archived
        let payload = SpotlightEventPayloadBuilder.payload(for: event, now: now)
        #expect(payload.statusLabel == "Archived")
    }

    // MARK: - Incremental indexing / deletion (FakeSpotlightIndexer)

    @Test func indexingAddsThePayloadKeyedByEventID() async {
        let indexer = FakeSpotlightIndexer()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
        #expect(indexer.indexedPayloads[event.id]?.title == "Interview")
        #expect(indexer.indexCallCount == 1)
    }

    @Test func reindexingTheSameEventReplacesRatherThanDuplicates() async {
        let indexer = FakeSpotlightIndexer()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
        event.title = "Rescheduled Interview"
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
        #expect(indexer.indexedPayloads.count == 1)
        #expect(indexer.indexedPayloads[event.id]?.title == "Rescheduled Interview")
    }

    @Test func removingAnEventDeletesItsPayload() async {
        let indexer = FakeSpotlightIndexer()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
        await indexer.remove(eventIDs: [event.id])
        #expect(indexer.indexedPayloads[event.id] == nil)
        #expect(indexer.removeCallCount == 1)
    }

    @Test func removeAllClearsEveryPayload() async {
        let indexer = FakeSpotlightIndexer()
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3_600))
        let b = makeEvent(title: "B", startDate: now.addingTimeInterval(7_200))
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: a, now: now), SpotlightEventPayloadBuilder.payload(for: b, now: now)])
        await indexer.removeAll()
        #expect(indexer.indexedPayloads.isEmpty)
        #expect(indexer.removeAllCallCount == 1)
    }

    // MARK: - Full reconciliation

    @Test func reindexAllIndexesEveryCurrentEvent() async {
        let context = makeContext()
        let indexer = FakeSpotlightIndexer()
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3_600))
        let b = makeEvent(title: "B", startDate: now.addingTimeInterval(7_200))
        context.insert(a)
        context.insert(b)
        try? context.save()

        let count = await SpotlightReconciliation.reindexAll(context: context, indexer: indexer, now: now)
        #expect(count == 2)
        #expect(Set(indexer.indexedPayloads.keys) == Set([a.id, b.id]))
    }

    @Test func reindexAllClearsStaleEntriesFirst() async {
        let context = makeContext()
        let indexer = FakeSpotlightIndexer()
        // A stale entry for an event that no longer exists in the store.
        await indexer.index([SpotlightEventPayload(eventID: UUID(), title: "Ghost", eventTypeDisplayName: "Generic", effectiveDate: now, isAllDay: false, statusLabel: "Upcoming")])

        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        context.insert(event)
        try? context.save()

        _ = await SpotlightReconciliation.reindexAll(context: context, indexer: indexer, now: now)
        #expect(indexer.indexedPayloads.count == 1)
        #expect(indexer.indexedPayloads[event.id] != nil)
    }

    @Test func reindexAllRemovesEverythingWhenIndexingIsDisabled() async {
        SpotlightIndexingPreference.setEnabled(false)
        defer { SpotlightIndexingPreference.setEnabled(SpotlightIndexingPreference.defaultEnabled) }

        let context = makeContext()
        let indexer = FakeSpotlightIndexer()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        context.insert(event)
        try? context.save()

        let count = await SpotlightReconciliation.reindexAll(context: context, indexer: indexer, now: now)
        #expect(count == 0)
        #expect(indexer.indexedPayloads.isEmpty)
        #expect(indexer.removeAllCallCount == 1)
    }
}
