//
//  SchemaV4MigrationTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — SchemaV3 → SchemaV4 migration proof. See docs/15-schema-migrations.md
//  step 6 and docs/31-kue-3-notification-studio.md "Migration". Reuses
//  `MigrationTestSupport`/`MigrationFixtures` exactly as every prior `SchemaVNMigrationTests`
//  file does — a real V1.0-shaped, on-disk store (never in-memory, never the production App
//  Group URL), reopened through `ModelContainerFactory`'s current, real migration plan (which
//  now carries all four stages: V1→V2→V3→V4).
//
//  `SchemaV1MigrationTests`/`SchemaV2MigrationTests`/`SchemaV3MigrationTests` already prove
//  every earlier field survives (all three route through `reopenThroughCurrentMigrationPlan`,
//  so bumping the plan to V4 re-verifies them for free). This file adds exactly what Phase 3
//  changed: `NotificationRule` exists in the migrated schema and starts empty for every
//  migrated event/task (the "no data to backfill, behavior preserved at the planner layer
//  instead" contract `KueSchemaV4.swift`'s header documents), and genuinely new, post-migration
//  event- and task-level rules round-trip through a further reopen with their relationships
//  intact.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
@Suite(.serialized, .migrationStoreSerialized)
struct SchemaV4MigrationTests {
    @Test func migratedV1EventsAndTasksHaveNoNotificationRulesYetTheyStillCountAsFullyConfigured() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let snapshot: MigrationFixtures.Snapshot
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopened.mainContext

        for eventSnapshot in snapshot.events {
            let id = eventSnapshot.id
            let event = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first)
            // No `NotificationRule` data existed before this phase — every migrated event
            // starts with an empty override list, meaning "inherit the global default,"
            // never "no notifications" (see `NotificationRule.swift`'s own header).
            #expect(event.notificationRules.isEmpty)
            for task in event.tasks {
                #expect(task.notificationRules.isEmpty)
            }
            // Spot-check this file is a meaningful proof on its own, not just a rerun under a
            // new name.
            #expect(event.title == eventSnapshot.title)
        }
    }

    @Test func notificationRuleIsPartOfTheMigratedSchemaAndStartsEmpty() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let rules = try reopened.mainContext.fetch(FetchDescriptor<NotificationRule>())
        #expect(rules.isEmpty)
    }

    @Test func reopeningTwiceInARowIsStableForTheNewRelationshipToo() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let snapshot: MigrationFixtures.Snapshot
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        _ = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let secondReopen = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)

        let id = try #require(snapshot.events.first).id
        let event = try #require(try secondReopen.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first)
        #expect(event.notificationRules.isEmpty)
    }

    /// docs/15-schema-migrations.md requirement 7 analog for this phase: genuinely new,
    /// post-migration event- and task-level `NotificationRule` rows (with their real
    /// relationships) must persist durably across a further, independent reopen — not just
    /// "the migration ran," but "the migrated store is a fully working V4 store afterward,"
    /// and cascade-delete still removes a rule when its owning event/task is deleted.
    @Test func newNotificationRulesWrittenAfterMigrationPersistAcrossAnotherReopen() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let eventID = UUID()
        let taskID = UUID()
        let eventRuleID = UUID()
        let taskRuleID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
            let event = KueEvent(id: eventID, title: "Board Review", eventType: .generic, startDate: start, estimatedDurationMinutes: 60, source: .manual)
            let task = KueTask(id: taskID, event: event, title: "Prep slides", dueDate: start.addingTimeInterval(-3600), offsetLabel: "1 hour before")
            event.tasks = [task]
            migrated.mainContext.insert(event)

            let eventRule = NotificationRule(id: eventRuleID, event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
            let taskRule = NotificationRule(id: taskRuleID, task: task, anchor: .taskDue, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes)
            migrated.mainContext.insert(eventRule)
            migrated.mainContext.insert(taskRule)
            try migrated.mainContext.save()
        }

        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopenedAgain.mainContext

        let event = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })).first)
        #expect(event.notificationRules.count == 1)
        #expect(event.notificationRules.first?.id == eventRuleID)
        #expect(event.notificationRules.first?.anchor == .eventStart)

        let task = try #require(event.tasks.first { $0.id == taskID })
        #expect(task.notificationRules.count == 1)
        #expect(task.notificationRules.first?.id == taskRuleID)

        // Cascade delete — deleting the event's owning graph must also remove its rules,
        // matching every other `deleteRule: .cascade` relationship this schema already has.
        context.delete(event)
        try context.save()
        let remainingRules = try context.fetch(FetchDescriptor<NotificationRule>(predicate: #Predicate { $0.id == eventRuleID || $0.id == taskRuleID }))
        #expect(remainingRules.isEmpty)
    }

    /// Kue 3.0 Phase 3 completion pass — docs/15/31 "Migration review": a genuine behavioral-
    /// equivalence proof, not just "the array happens to be empty." A migrated event with zero
    /// `NotificationRule` rows must plan *identically* to a freshly-created (never migrated)
    /// event with the same shape and zero rules — proving the empty array really does mean
    /// "inherit the global default" and not some silently-different "disabled" behavior a
    /// migration could in principle have introduced.
    @Test func aMigratedZeroRuleEventPlansIdenticallyToAFreshlyCreatedOneWithTheSameShape() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let eventID = UUID()
        let startDate = Date(timeIntervalSince1970: 1_800_003_600)
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            let event = KueSchemaV1.KueEvent(
                id: eventID, title: "Migrated Review", eventType: .generic, startDate: startDate,
                estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual, schemaVersion: 1
            )
            v1Container.mainContext.insert(event)
            try v1Container.mainContext.save()
        }

        let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let migratedEvent = try #require(try migrated.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })).first)
        #expect(migratedEvent.notificationRules.isEmpty)

        let freshEvent = KueEvent(
            id: UUID(), title: "Migrated Review", eventType: .generic, startDate: startDate,
            estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual
        )

        let planInput = { (event: KueEvent) in
            NotificationPlanner.Input(events: [event], globalPreferences: .conservativeDefault, intensity: .standard, authorizationGranted: true, now: Date(timeIntervalSince1970: 1_800_000_000), capacity: 64)
        }
        let migratedPlan = NotificationPlanner.plan(planInput(migratedEvent))
        let freshPlan = NotificationPlanner.plan(planInput(freshEvent))

        // Identifiers differ only by the (different) event UUID prefix each carries — strip
        // that off and compare the rest ("-event-start", "-outcome-follow-up", etc.) plus every
        // other planned field, so this is a genuine content comparison, not just a count check.
        func stripEventID(_ identifier: String, eventID: UUID) -> String {
            identifier.replacingOccurrences(of: eventID.uuidString, with: "")
        }
        let migratedSuffixes = Set(migratedPlan.scheduledCandidates.map { stripEventID($0.identifier, eventID: migratedEvent.id) })
        let freshSuffixes = Set(freshPlan.scheduledCandidates.map { stripEventID($0.identifier, eventID: freshEvent.id) })
        #expect(migratedSuffixes == freshSuffixes)
        #expect(!migratedSuffixes.isEmpty) // sanity: this event type does produce real defaults
        #expect(migratedPlan.scheduledCandidates.map(\.title).sorted() == freshPlan.scheduledCandidates.map(\.title).sorted())
        #expect(migratedPlan.scheduledCandidates.map(\.body).sorted() == freshPlan.scheduledCandidates.map(\.body).sorted())
    }
}
