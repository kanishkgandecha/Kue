//
//  KueTests.swift
//  KueTests
//
//  Foundational model/container tests for Phase 1 (M0 — Foundation). See
//  docs/03-data-model.md for the fields being verified and docs/10-testing-strategy.md
//  for how this maps to later phases. Only the in-memory path is exercised here —
//  makeDefault() touches disk and is exercised implicitly by the app running.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct KueTests {

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    // MARK: - Round trip

    @Test func kueEventRoundTrip() throws {
        let context = makeContext()
        let event = KueEvent(
            title: "Salesforce Interview",
            eventType: .interview,
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            estimatedDurationMinutes: 60,
            source: .manual
        )
        context.insert(event)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Salesforce Interview")
        #expect(fetched.first?.eventType == .interview)
        #expect(fetched.first?.status == .upcoming) // default for a freshly created event
        #expect(fetched.first?.isCancelled == false)
        #expect(fetched.first?.isManuallyCompleted == false)
        #expect(fetched.first?.schemaVersion == 1)
    }

    @Test func taskRelationshipRoundTrip() throws {
        let context = makeContext()
        let event = KueEvent(title: "OS Exam", eventType: .exam, startDate: .now, estimatedDurationMinutes: 120, source: .manual)
        let task = KueTask(event: event, title: "Review chapter 1", dueDate: .now, offsetLabel: "3 days before")
        event.tasks.append(task)
        context.insert(event)
        try context.save()

        let fetchedTasks = try context.fetch(FetchDescriptor<KueTask>())
        #expect(fetchedTasks.count == 1)
        #expect(fetchedTasks.first?.event?.id == event.id)
        #expect(fetchedTasks.first?.offsetLabel == "3 days before")
    }

    // MARK: - Relationship deletion (cascade)

    @Test func deletingEventCascadesToAllChildren() throws {
        let context = makeContext()
        let event = KueEvent(
            title: "Trip",
            eventType: .trip,
            startDate: .now,
            endDate: .now.addingTimeInterval(3 * 86_400),
            estimatedDurationMinutes: 0,
            source: .manual
        )
        let task = KueTask(event: event, title: "Pack", dueDate: .now, offsetLabel: "1 day before")
        let schedule = KueSchedule(event: event, templateType: .trip)
        let widgetConfiguration = WidgetConfiguration(event: event, widgetType: .timeline)
        let widgetState = WidgetState(event: event, currentPhase: .countdown, headline: "Trip in 3 days", nextTransitionDate: .now)

        event.tasks.append(task)
        event.schedule = schedule
        event.widgetConfiguration = widgetConfiguration
        event.widgetState = widgetState

        context.insert(event)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<KueTask>()).count == 1)

        context.delete(event)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<KueEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KueTask>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KueSchedule>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WidgetConfiguration>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WidgetState>()).isEmpty)
    }

    // MARK: - effectiveEndDate (docs/03-data-model.md "Completion timing")

    @Test func effectiveEndDateForTimedZeroDurationEventIsStartDate() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = KueEvent(title: "Deadline", eventType: .deadline, startDate: start, estimatedDurationMinutes: 0, source: .manual)
        #expect(event.effectiveEndDate == start)
    }

    @Test func effectiveEndDateForTimedNonZeroDurationEventAddsMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: start, estimatedDurationMinutes: 60, source: .manual)
        #expect(event.effectiveEndDate == start.addingTimeInterval(60 * 60))
    }

    @Test func effectiveEndDateForTripUsesEndDate() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let end = start.addingTimeInterval(3 * 86_400)
        let event = KueEvent(title: "Trip", eventType: .trip, startDate: start, endDate: end, estimatedDurationMinutes: 0, source: .manual)
        #expect(event.effectiveEndDate == end)
    }

    @Test func effectiveEndDateForAllDayEventIsEndOfDayNotMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000_000_000))
        let event = KueEvent(
            title: "All-day deadline",
            eventType: .deadline,
            startDate: midnight,
            estimatedDurationMinutes: 0,
            isAllDay: true,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        let expectedEnd = calendar.date(byAdding: .day, value: 1, to: midnight)!
        #expect(event.effectiveEndDate == expectedEnd)
        #expect(event.effectiveEndDate != midnight) // must not complete at the instant it starts
    }
}
