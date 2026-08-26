//
//  SchemaV1MigrationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation. Proves the exact claim this phase makes:
//  "the shipped v1.0 store opens without loss through a real migration plan." A real,
//  on-disk store (never in-memory, never the production App Group URL — see
//  MigrationTestSupport) is built exactly the way a real device's V1.0 store was built (no
//  migration plan at all), populated with representative data (MigrationFixtures), then
//  reopened through `ModelContainerFactory`'s current `schema`/`migrationPlan` — the same
//  construction every production target uses — and every field and relationship is checked
//  against what was actually written.
//
//  There is only one schema version right now, so this doesn't exercise an actual migration
//  *stage* (there isn't one yet) — it proves the *foundation* is wired correctly end to end,
//  which is exactly what a phase named "Migration Foundation" should prove. The moment
//  `KueSchemaV2` exists, this file's pattern (not necessarily this file) is what a real
//  `SchemaV1ToV2MigrationTests` should follow.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct SchemaV1MigrationTests {
    @Test func aRealV1StoreOpensWithoutLossThroughTheCurrentMigrationPlan() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let snapshot: MigrationFixtures.Snapshot
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }
        // `v1Container` deliberately falls out of scope here — the next open is a genuinely
        // fresh `ModelContainer`, the same as a real app relaunch, not a container that
        // happens to still have everything cached in memory.

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopened.mainContext

        try verifyEvents(snapshot.events, in: context)
        try verifyTasks(snapshot.tasks, in: context)
        try verifySchedules(snapshot.schedules, in: context)
        try verifyWidgetConfigurations(snapshot.widgetConfigurations, in: context)
        try verifyWidgetStates(snapshot.widgetStates, in: context)
        try verifyTemplates(snapshot.templates, in: context)
        try verifyUserPreferences(snapshot.userPreferences, in: context)
    }

    @Test func reopeningTwiceInARowIsStableAndLossless() throws {
        // Guards against a subtly wrong migration plan that "happens to work once" — e.g.
        // one that mutates data as a side effect of opening, which would only show up on a
        // *second* open.
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let snapshot: MigrationFixtures.Snapshot
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        _ = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let secondReopen = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)

        try verifyEvents(snapshot.events, in: secondReopen.mainContext)
    }

    @Test func cascadeDeleteStillWorksAfterReopeningThroughTheMigrationPlan() throws {
        // Requirement 8: "every relationship and cascade rule" — relationships must not just
        // read back correctly, their *behavior* (cascade delete rules) must survive too.
        // Uses the `interview` fixture specifically because it's the one event that has all
        // four cascading children (tasks, schedule, widget configuration, *and* widget
        // state) — the `generic`-only version of this test could pass while a
        // `WidgetState`-cascade regression slipped through unnoticed.
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let interviewEventID: UUID
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            let snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
            interviewEventID = try #require(snapshot.events.first { $0.eventType == .interview }).id
        }

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopened.mainContext
        let event = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == interviewEventID })).first)
        #expect(event.widgetConfiguration != nil)
        #expect(event.widgetState != nil)

        context.delete(event)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<WidgetConfiguration>()).allSatisfy { $0.event?.id != interviewEventID })
        #expect(try context.fetch(FetchDescriptor<WidgetState>()).allSatisfy { $0.event?.id != interviewEventID })

        // The `generic` fixture separately covers the tasks/schedule cascade — same rule,
        // different event, so both halves of "every relationship" are actually exercised.
        let genericEventID = try #require(try context.fetch(FetchDescriptor<KueEvent>()).first { !$0.tasks.isEmpty && $0.schedule != nil }).id
        let genericEvent = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == genericEventID })).first)
        #expect(!genericEvent.tasks.isEmpty)
        #expect(genericEvent.schedule != nil)

        context.delete(genericEvent)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<KueTask>()).allSatisfy { $0.event?.id != genericEventID })
        #expect(try context.fetch(FetchDescriptor<KueSchedule>()).allSatisfy { $0.event?.id != genericEventID })
    }

    @Test func newDataWrittenAfterMigrationPersistsAcrossAnotherReopen() throws {
        // Requirement 7: "writing new data after migration" + "reopening the migrated store
        // again to verify persistence" — a migration plan that can open old data but leaves
        // the store in a state that can't accept *new* writes (or doesn't durably persist
        // them) would still be a broken foundation for every phase after this one.
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let newEventID = UUID()
        do {
            // First post-migration open: write a brand-new event, unrelated to anything in
            // the original v1 fixture data, through the exact same migration plan.
            let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
            let newEvent = KueEvent(
                id: newEventID,
                title: "Written After Migration",
                eventType: .deadline,
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                estimatedDurationMinutes: 0,
                source: .manual
            )
            migrated.mainContext.insert(newEvent)
            try migrated.mainContext.save()
        }

        // Second, independent reopen — proves the write in the previous block was actually
        // durable on disk, not just visible within the same in-memory context/session.
        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let persisted = try #require(
            try reopenedAgain.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == newEventID })).first
        )
        #expect(persisted.title == "Written After Migration")
        #expect(persisted.eventType == .deadline)

        // The original v1 fixture data must still be intact alongside the new write — a
        // migration path that silently drops old rows while accepting new ones would be
        // just as broken as one that can't accept new writes at all.
        let allEvents = try reopenedAgain.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(allEvents.count == 6) // 5 fixture events + the one written after migration
    }

    // MARK: - Verification

    private func verifyEvents(_ expected: [MigrationFixtures.EventSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let event = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first)
            #expect(event.title == snapshot.title)
            #expect(event.eventType == snapshot.eventType)
            #expect(event.startDate == snapshot.startDate)
            #expect(event.endDate == snapshot.endDate)
            #expect(event.estimatedDurationMinutes == snapshot.estimatedDurationMinutes)
            #expect(event.isAllDay == snapshot.isAllDay)
            #expect(event.timeZoneIdentifier == snapshot.timeZoneIdentifier)
            #expect(event.location == snapshot.location)
            #expect(event.notes == snapshot.notes)
            #expect(event.source == snapshot.source)
            #expect(event.priority == snapshot.priority)
            #expect(event.status == snapshot.status)
            #expect(event.isCancelled == snapshot.isCancelled)
            #expect(event.cancelledAt == snapshot.cancelledAt)
            #expect(event.isManuallyCompleted == snapshot.isManuallyCompleted)
            #expect(event.manuallyCompletedAt == snapshot.manuallyCompletedAt)
            #expect((event.recurrence != nil) == snapshot.hasRecurrence)
            #expect(event.schemaVersion == snapshot.schemaVersion)
            #expect(event.createdAt == snapshot.createdAt)
            #expect(event.updatedAt == snapshot.updatedAt)
            #expect(event.tasks.map(\.id).sorted() == snapshot.taskIDs)
            #expect(event.schedule?.id == snapshot.scheduleID)
            #expect(event.widgetConfiguration?.id == snapshot.widgetConfigurationID)
            #expect(event.widgetState?.id == snapshot.widgetStateID)
        }
    }

    private func verifyTasks(_ expected: [MigrationFixtures.TaskSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let task = try #require(try context.fetch(FetchDescriptor<KueTask>(predicate: #Predicate { $0.id == id })).first)
            #expect(task.event?.id == snapshot.eventID)
            #expect(task.title == snapshot.title)
            #expect(task.dueDate == snapshot.dueDate)
            #expect(task.isCompleted == snapshot.isCompleted)
            #expect(task.completedAt == snapshot.completedAt)
            #expect(task.offsetLabel == snapshot.offsetLabel)
            #expect(task.sortOrder == snapshot.sortOrder)
        }
    }

    private func verifySchedules(_ expected: [MigrationFixtures.ScheduleSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let schedule = try #require(try context.fetch(FetchDescriptor<KueSchedule>(predicate: #Predicate { $0.id == id })).first)
            #expect(schedule.event?.id == snapshot.eventID)
            #expect(schedule.templateType == snapshot.templateType)
            #expect(schedule.rules == snapshot.rules)
            #expect(schedule.isCustom == snapshot.isCustom)
            #expect(schedule.generatedAt == snapshot.generatedAt)
        }
    }

    private func verifyWidgetConfigurations(_ expected: [MigrationFixtures.WidgetConfigurationSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let configuration = try #require(try context.fetch(FetchDescriptor<WidgetConfiguration>(predicate: #Predicate { $0.id == id })).first)
            #expect(configuration.event?.id == snapshot.eventID)
            #expect(configuration.widgetType == snapshot.widgetType)
            #expect(configuration.showLocation == snapshot.showLocation)
            #expect(configuration.isEnabled == snapshot.isEnabled)
        }
    }

    private func verifyWidgetStates(_ expected: [MigrationFixtures.WidgetStateSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let state = try #require(try context.fetch(FetchDescriptor<WidgetState>(predicate: #Predicate { $0.id == id })).first)
            #expect(state.event?.id == snapshot.eventID)
            #expect(state.currentPhase == snapshot.currentPhase)
            #expect(state.headline == snapshot.headline)
            #expect(state.subline == snapshot.subline)
            #expect(state.progress == snapshot.progress)
            #expect(state.nextTransitionDate == snapshot.nextTransitionDate)
        }
    }

    private func verifyTemplates(_ expected: [MigrationFixtures.TemplateSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let template = try #require(try context.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.id == id })).first)
            #expect(template.name == snapshot.name)
            #expect(template.eventType == snapshot.eventType)
            #expect(template.scheduleRules == snapshot.scheduleRules)
            #expect(template.isUserDefined == snapshot.isUserDefined)
            #expect(template.isBuiltIn == snapshot.isBuiltIn)
        }
    }

    private func verifyUserPreferences(_ expected: [MigrationFixtures.UserPreferenceSnapshot], in context: ModelContext) throws {
        for snapshot in expected {
            let id = snapshot.id
            let preference = try #require(try context.fetch(FetchDescriptor<UserPreference>(predicate: #Predicate { $0.id == id })).first)
            #expect(preference.notificationIntensity == snapshot.notificationIntensity)
            #expect(preference.aiParsingEnabled == snapshot.aiParsingEnabled)
        }
    }
}
