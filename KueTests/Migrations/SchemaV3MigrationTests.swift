//
//  SchemaV3MigrationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 4 — SchemaV2 → SchemaV3 migration proof. See docs/15-schema-migrations.md
//  step 6 and docs/18-calendar-integration.md "Migration". Reuses
//  `MigrationTestSupport`/`MigrationFixtures` exactly as `SchemaV1MigrationTests`/
//  `SchemaV2MigrationTests` do — a real V1.0-shaped, on-disk store (never in-memory, never the
//  production App Group URL), reopened through `ModelContainerFactory`'s current, real
//  migration plan (which now carries both stages: V1→V2→V3).
//
//  `SchemaV1MigrationTests` already proves every V1.0 field survives to the current schema;
//  `SchemaV2MigrationTests` already proves every Phase-3 recurrence field does too (both route
//  through `reopenThroughCurrentMigrationPlan`, so bumping the plan to V3 re-verifies them for
//  free — requirement 23: "all v1.0, Phase 2, Phase 3 data survives"). This file adds exactly
//  what Phase 4 changed: the five new `KueEvent` Calendar-linkage fields are nil-backfilled on
//  every migrated row, and genuinely new (post-migration) Calendar-linked data round-trips
//  through a further reopen.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct SchemaV3MigrationTests {
    @Test func migratedV1EventsGetNilCalendarLinkageFields() throws {
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
            #expect(event.externalCalendarEventIdentifier == nil)
            #expect(event.externalCalendarIdentifier == nil)
            #expect(event.externalCalendarTitle == nil)
            #expect(event.externalCalendarLastSyncedAt == nil)
            #expect(event.externalCalendarLastKnownModifiedAt == nil)
            // Spot-check this file is a meaningful proof on its own, not just a rerun under a
            // new name.
            #expect(event.title == eventSnapshot.title)
        }
    }

    @Test func reopeningTwiceInARowIsStableForTheNewCalendarFieldsToo() throws {
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
        #expect(event.externalCalendarEventIdentifier == nil)
    }

    /// docs/15-schema-migrations.md requirement 7 analog for this phase: genuinely new,
    /// post-migration Calendar-linked data must persist durably across a further, independent
    /// reopen.
    @Test func newCalendarLinkedDataWrittenAfterMigrationPersistsAcrossAnotherReopen() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            MigrationFixtures.insertRepresentativeData(into: v1Container.mainContext)
        }

        let linkedEventID = UUID()
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let lastKnownModified = syncedAt.addingTimeInterval(-60)

        do {
            let migrated = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
            let linked = KueEvent(
                id: linkedEventID, title: "Exported Event", eventType: .generic, startDate: syncedAt,
                estimatedDurationMinutes: 30, source: .manual,
                externalCalendarEventIdentifier: "ext-123",
                externalCalendarIdentifier: "cal-456",
                externalCalendarTitle: "Home",
                externalCalendarLastSyncedAt: syncedAt,
                externalCalendarLastKnownModifiedAt: lastKnownModified
            )
            migrated.mainContext.insert(linked)
            try migrated.mainContext.save()
        }

        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let context = reopenedAgain.mainContext

        let linked = try #require(try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == linkedEventID })).first)
        #expect(linked.externalCalendarEventIdentifier == "ext-123")
        #expect(linked.externalCalendarIdentifier == "cal-456")
        #expect(linked.externalCalendarTitle == "Home")
        #expect(linked.externalCalendarLastSyncedAt == syncedAt)
        #expect(linked.externalCalendarLastKnownModifiedAt == lastKnownModified)

        // The original v1 fixture data must still be intact alongside the new linked event.
        let allEvents = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(allEvents.count == 6) // 5 fixture events + the 1 new Calendar-linked event
    }
}
