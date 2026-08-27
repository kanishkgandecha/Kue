//
//  SchemaV2MigrationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 3 — SchemaV1 → SchemaV2 migration proof. See docs/15-schema-migrations.md
//  step 6 ("a migration test with a representative fixture covering the changed shape") and
//  docs/17-recurring-events.md "Migration". Reuses `MigrationTestSupport`/`MigrationFixtures`
//  exactly as `SchemaV1MigrationTests` does — a real V1.0-shaped, on-disk store (never
//  in-memory, never the production App Group URL), reopened through
//  `ModelContainerFactory`'s current, real migration plan.
//
//  `SchemaV1MigrationTests` already proves every pre-existing V1.0 field survives losslessly;
//  this file adds exactly what Phase 3 changed: the five new `KueEvent` fields are correctly
//  backfilled to their non-recurring defaults on migrated V1 rows, `RecurrenceExclusion` exists
//  in the migrated schema, and genuinely new (post-migration) recurring data round-trips
//  through a further reopen just as durably as `SchemaV1MigrationTests`
//  `newDataWrittenAfterMigrationPersistsAcrossAnotherReopen` proves for plain data.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct SchemaV2MigrationTests {
    @Test func migratedV1EventsGetNonRecurringDefaultsForEveryNewField() throws {
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
            // Every real V1.0 row is non-recurring — explicit, verifiable defaults (this is
            // the `.custom` migration stage's own `didMigrate` backfill, not SwiftData
            // inference). `recurrence` is included here deliberately: it's genuinely new as of
            // this schema version (real V1.0 rows have no `ZRECURRENCE` column at all — see
            // `KueSchemaV1.swift`'s header), not a pre-existing field being re-checked.
            #expect(event.recurrence == nil)
            #expect(event.seriesID == nil)
            #expect(event.recurrenceAnchorDate == nil)
            #expect(event.isRecurrenceException == false)
            #expect(event.isSkipped == false)
            #expect(event.skippedAt == nil)
            // Spot-check a couple of pre-existing fields too, so this file is a meaningful
            // proof on its own, not just a rerun of SchemaV1MigrationTests under a new name.
            #expect(event.title == eventSnapshot.title)
            #expect(event.schemaVersion == eventSnapshot.schemaVersion)
        }
    }

    @Test func recurrenceExclusionIsPartOfTheMigratedSchemaAndStartsEmpty() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let exclusions = try reopened.mainContext.fetch(FetchDescriptor<RecurrenceExclusion>())
        #expect(exclusions.isEmpty)
    }

    @Test func reopeningTwiceInARowIsStableForTheNewFieldsToo() throws {
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
        #expect(event.seriesID == nil)
        #expect(event.isRecurrenceException == false)
    }

    /// docs/15-schema-migrations.md requirement 7 analog for this phase: genuinely new,
    /// post-migration recurring data (a real series with an exception and an exclusion) must
    /// persist durably across a further, independent reopen — not just "the migration ran,"
    /// but "the migrated store is a fully working V2 store afterward."
    @Test func newRecurringDataWrittenAfterMigrationPersistsAcrossAnotherReopen() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let seriesID = UUID()
        let firstOccurrenceID = UUID()
        let secondOccurrenceID = UUID()
        let anchor1 = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor2 = anchor1.addingTimeInterval(7 * 86_400)
        let excludedAnchor = anchor1.addingTimeInterval(14 * 86_400)

        do {
            let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
            let first = KueEvent(
                id: firstOccurrenceID, title: "Weekly Sync", eventType: .generic, startDate: anchor1,
                estimatedDurationMinutes: 0, source: .manual,
                seriesID: seriesID, recurrenceAnchorDate: anchor1
            )
            first.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
            let second = KueEvent(
                id: secondOccurrenceID, title: "Weekly Sync (customized)", eventType: .generic, startDate: anchor2,
                estimatedDurationMinutes: 0, source: .manual,
                seriesID: seriesID, recurrenceAnchorDate: anchor2, isRecurrenceException: true
            )
            second.recurrence = first.recurrence
            migrated.mainContext.insert(first)
            migrated.mainContext.insert(second)
            migrated.mainContext.insert(RecurrenceExclusion(seriesID: seriesID, excludedAnchorDate: excludedAnchor))
            try migrated.mainContext.save()
        }

        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopenedAgain.mainContext

        let first = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == firstOccurrenceID })).first)
        #expect(first.seriesID == seriesID)
        #expect(first.recurrenceAnchorDate == anchor1)
        #expect(first.recurrence?.frequency == .weekly)
        #expect(first.recurrence?.interval == 1)
        #expect(first.isRecurrenceException == false)

        let second = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == secondOccurrenceID })).first)
        #expect(second.seriesID == seriesID)
        #expect(second.isRecurrenceException)
        #expect(second.title == "Weekly Sync (customized)")

        let exclusions = try context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.seriesID == seriesID }))
        #expect(exclusions.count == 1)
        #expect(exclusions.first?.excludedAnchorDate == excludedAnchor)

        // The original v1 fixture data must still be intact alongside the new recurring data.
        let allEvents = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(allEvents.count == 7) // 5 fixture events + the 2 new recurring occurrences
    }
}
