//
//  KueOneUpgradeReleaseVerificationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 12 — docs/28 "O." RELEASE BLOCKER: a real Kue 1.0 store must upgrade safely.
//  The structural side (schema migration, cascade deletes, reopen stability, legacy-recovery
//  security) is already covered exhaustively by `SchemaV1MigrationTests`/`SchemaV2MigrationTests`/
//  `SchemaV3MigrationTests`/`RealV1SchemaRegressionTests`/`LegacyRecoverySecurityTests`/
//  `RealStoreCopyVerification` — this file adds only the two behavioral guarantees docs/28 "O."
//  names that those files don't already cover: a migrated pre-1.0 event whose date has passed
//  becomes "Needs Review" rather than silently `.completed` (docs/25), and the new Phase 12
//  backup feature works immediately on a freshly-migrated store. Every store here is synthetic
//  (`MigrationTestSupport`) — never real user data.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite(.serialized, .migrationStoreSerialized)
struct KueOneUpgradeReleaseVerificationTests {
    /// docs/25 "A.": scheduled time passing is never proof an event happened — this must hold
    /// for an event that predates Phase 10.1 (and `isManuallyCompleted`) entirely, not just one
    /// created after that field existed. A V1.0 store never had `isManuallyCompleted` at all;
    /// migration must default it to `false` (proven separately by `SchemaV2MigrationTests.
    /// migratedV1EventsGetNonRecurringDefaultsForEveryNewField`), and `EventStatusEngine.derive`
    /// must then treat that exactly like any other unconfirmed event — this test proves the two
    /// facts actually compose correctly end-to-end through the real migration plan, not just
    /// independently.
    @Test func aMigratedV1EventWhoseDateHasPassedBecomesNeedsReviewNotSilentlyCompleted() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let v1Container = try MigrationTestSupport.makeV1Store(at: url)
        let v1Context = ModelContext(v1Container)
        v1Context.insert(KueSchemaV1.KueEvent(
            title: "Old Reminder", eventType: .generic, startDate: past,
            estimatedDurationMinutes: 30, isAllDay: false, timeZoneIdentifier: "UTC",
            source: .manual, priority: .medium, status: .upcoming, schemaVersion: 1
        ))
        try v1Context.save()

        let migratedContainer = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let migratedContext = ModelContext(migratedContainer)
        let migrated = try migratedContext.fetch(FetchDescriptor<KueEvent>()).first
        #expect(migrated?.isManuallyCompleted == false)

        // "Now" is well after the event's own end — the exact scenario docs/25 exists for.
        let now = past.addingTimeInterval(30 * 86_400)
        #expect(EventStatusEngine.derive(for: try #require(migrated), now: now) == .awaitingOutcome)
    }

    /// docs/28 "E./O.": the Personal-build/free-team story only works if a user can back up
    /// their data right after upgrading, before doing anything else — proves the Phase 12
    /// backup feature (Shared/Services/Backup/) works against a store that just came through
    /// the real migration plan, not only against a store built fresh in-memory.
    @Test func backupExportSucceedsImmediatelyAfterMigratingAV1Store() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let v1Container = try MigrationTestSupport.makeV1Store(at: url)
        let v1Context = ModelContext(v1Container)
        v1Context.insert(KueSchemaV1.KueEvent(
            title: "Pre-Upgrade Event", eventType: .exam, startDate: Date(timeIntervalSince1970: 1_700_500_000),
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            source: .manual, priority: .high, status: .upcoming, schemaVersion: 1
        ))
        try v1Context.save()

        let migratedContainer = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let migratedContext = ModelContext(migratedContainer)

        let data = try BackupCoder.exportData(context: migratedContext)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)
        #expect(payload.events.count == 1)
        #expect(payload.events.first?.title == "Pre-Upgrade Event")
    }
}
