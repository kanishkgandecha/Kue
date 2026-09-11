//
//  SchemaV5MigrationTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 completion pass — SchemaV4 → SchemaV5 migration proof. See
//  docs/15-schema-migrations.md step 6 and docs/31-kue-3-notification-studio.md "Template
//  notification defaults." Reuses `MigrationTestSupport`/`MigrationFixtures` exactly as every
//  prior `SchemaVNMigrationTests` file does.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
@Suite(.serialized, .migrationStoreSerialized)
struct SchemaV5MigrationTests {
    /// A real V1.0-shaped store has no `Template` rows at all (Templates were never persisted
    /// before Kue 2.0 Phase 12's backup format existed) — this test instead inserts one
    /// directly at the migration boundary, mirroring `SchemaV4MigrationTests`'
    /// `newNotificationRulesWrittenAfterMigrationPersistAcrossAnotherReopen`'s own "insert
    /// after reaching the current plan, then reopen again" shape, so it still proves a
    /// **real, existing** row survives this specific stage's backfill losslessly.
    @Test func aTemplateRowPredatingThisPhaseGetsAnEmptyNotificationDefaultsArray() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let templateID = UUID()
        do {
            // Built via `KueSchemaV4` directly (not the live type) — the exact pre-Phase-3-
            // completion-pass shape a real backup-restored or otherwise pre-existing Template
            // row would have on disk.
            let v4Schema = Schema(versionedSchema: KueSchemaV4.self)
            let configuration = ModelConfiguration(schema: v4Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v4Schema, configurations: [configuration])
            let template = KueSchemaV4.Template(id: templateID, name: "Exam", eventType: .exam, scheduleRules: [], isUserDefined: false, isBuiltIn: true)
            container.mainContext.insert(template)
            try container.mainContext.save()
        }

        let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let template = try #require(try migrated.mainContext.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.id == templateID })).first)
        #expect(template.notificationRuleDefaults.isEmpty)
        // The pre-existing field survives untouched alongside the new one.
        #expect(template.name == "Exam")
        #expect(template.eventType == .exam)
    }

    @Test func reopeningTwiceInARowIsStableForTheNewTemplateFieldToo() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let templateID = UUID()
        do {
            let v4Schema = Schema(versionedSchema: KueSchemaV4.self)
            let configuration = ModelConfiguration(schema: v4Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v4Schema, configurations: [configuration])
            container.mainContext.insert(KueSchemaV4.Template(id: templateID, name: "Trip", eventType: .trip))
            try container.mainContext.save()
        }

        _ = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let secondReopen = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let template = try #require(try secondReopen.mainContext.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.id == templateID })).first)
        #expect(template.notificationRuleDefaults.isEmpty)
    }

    /// docs/15-schema-migrations.md requirement 7 analog: genuinely new, post-migration
    /// template notification defaults must persist durably across a further, independent
    /// reopen.
    @Test func newTemplateNotificationDefaultsWrittenAfterMigrationPersistAcrossAnotherReopen() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let templateID = UUID()
        let ruleID = UUID()
        do {
            let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
            let template = Template(id: templateID, name: "Interview", eventType: .interview)
            template.notificationRuleDefaults = [
                NotificationRuleDefault(id: ruleID, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
            ]
            migrated.mainContext.insert(template)
            try migrated.mainContext.save()
        }

        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let template = try #require(try reopenedAgain.mainContext.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.id == templateID })).first)
        #expect(template.notificationRuleDefaults.count == 1)
        #expect(template.notificationRuleDefaults.first?.id == ruleID)
        #expect(template.notificationRuleDefaults.first?.offsetQuantity == 15)

        // The original v1 fixture data must still be intact alongside the new template.
        let allEvents = try reopenedAgain.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(allEvents.count == 5) // 5 fixture events, unaffected by this stage
    }

    @Test func aFullV1ToV5ChainMigratesLosslessly() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let snapshot: MigrationFixtures.Snapshot
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            snapshot = MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        for eventSnapshot in snapshot.events {
            let id = eventSnapshot.id
            let event = try #require(try migrated.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first)
            #expect(event.title == eventSnapshot.title)
            #expect(event.notificationRules.isEmpty)
        }
    }
}
