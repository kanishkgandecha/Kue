//
//  EventCRUDTests.swift
//  KueTests
//
//  CRUD across all five V1 event types, plus EventActions' cancel/complete mutual
//  exclusivity and archive/unarchive — docs/04-event-types.md, docs/10-testing-strategy.md.
//  Round trip + cascade-delete for a single event are already covered in KueTests.swift
//  (Phase 1); this file adds update, per-type create, and the Phase 2 action services.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

// `.eventActionsSyncOutboxSerialized` — see EventActionsSyncOutboxTestLock.swift: `EventActions.
// skip`/`complete`/`archive`/`unarchive`/`unskip` all touch the real, process-global
// `SystemCloudSyncStateStore.shared`.
@Suite(.eventActionsSyncOutboxSerialized)
@MainActor
struct EventCRUDTests {

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test(arguments: EventType.allCases)
    func createsAndFetchesEveryEventType(eventType: EventType) throws {
        let context = makeContext()
        let event = KueEvent(
            title: "\(eventType.rawValue) event",
            eventType: eventType,
            startDate: .now,
            endDate: eventType == .trip ? .now.addingTimeInterval(86_400) : nil,
            estimatedDurationMinutes: eventType.defaultEstimatedDurationMinutes,
            source: .manual
        )
        context.insert(event)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.eventType == eventType)
    }

    @Test func updatingFieldsPersists() throws {
        let context = makeContext()
        let event = KueEvent(title: "Old Title", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        event.title = "New Title"
        event.location = "Somewhere"
        event.updatedAt = .now
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched.first?.title == "New Title")
        #expect(fetched.first?.location == "Somewhere")
    }

    @Test func deletingRemovesFromStore() throws {
        let context = makeContext()
        let event = KueEvent(title: "Gone Soon", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.delete(event, context: context)

        #expect(try context.fetch(FetchDescriptor<KueEvent>()).isEmpty)
    }

    // MARK: - Cancel / complete mutual exclusivity (requirement 6)

    @Test func cancellingClearsManualCompletion() throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.complete(event, context: context)
        #expect(event.isManuallyCompleted)

        EventActions.cancel(event, context: context)
        #expect(event.isCancelled)
        #expect(event.isManuallyCompleted == false)
        #expect(event.status == .cancelled)
    }

    @Test func completingClearsCancellation() throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.cancel(event, context: context)
        #expect(event.isCancelled)

        EventActions.complete(event, context: context)
        #expect(event.isManuallyCompleted)
        #expect(event.isCancelled == false)
        #expect(event.status == .completed)
    }

    // MARK: - Kue 2.0 Phase 3 — skip (docs/17-recurring-events.md "Occurrence actions")

    @Test func skipReusesCancelledAsItsDerivedStatusButSetsItsOwnField() throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.skip(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.isSkipped)
        #expect(event.skippedAt != nil)
        #expect(event.status == .cancelled)
        #expect(event.isCancelled == false)
        #expect(event.isManuallyCompleted == false)
    }

    @Test func skipClearsCancelAndManualCompletion() throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.complete(event, context: context)
        #expect(event.isManuallyCompleted)

        EventActions.skip(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.isSkipped)
        #expect(event.isManuallyCompleted == false)
    }

    @Test func cancelWinsOverSkipWhenBothAreSomehowSet() throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()

        EventActions.skip(event, context: context)
        EventActions.cancel(event, context: context)
        // `cancel` doesn't itself clear `isSkipped` (only `skip`/`complete`/`cancel` clear each
        // OTHER's field), but derive()'s precedence still resolves to cancelled either way —
        // this documents the precedence rather than depending on cancel clearing skip.
        #expect(EventStatusEngine.derive(for: event) == .cancelled)
    }

    @Test func unskipRestoresDerivedStatus() async throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()
        #expect(event.status == .upcoming)

        EventActions.skip(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.status == .cancelled)

        await EventActions.unskip(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.isSkipped == false)
        #expect(event.status == .upcoming)
    }

    // MARK: - Archive / unarchive

    @Test func archiveThenUnarchiveRestoresDerivedStatus() async throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()
        #expect(event.status == .upcoming)

        EventActions.archive(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.status == .archived)

        await EventActions.unarchive(
            event,
            context: context,
            scheduler: FakeNotificationScheduler(),
            liveActivityManager: FakeLiveActivityManager(),
            spotlightIndexer: FakeSpotlightIndexer()
        )
        #expect(event.status == .upcoming)
    }
}
