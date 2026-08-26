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

    // MARK: - Archive / unarchive

    @Test func archiveThenUnarchiveRestoresDerivedStatus() async throws {
        let context = makeContext()
        let event = KueEvent(title: "E", eventType: .generic, startDate: .distantFuture, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()
        #expect(event.status == .upcoming)

        await EventActions.archive(event, context: context)
        #expect(event.status == .archived)

        await EventActions.unarchive(event, context: context)
        #expect(event.status == .upcoming)
    }
}
