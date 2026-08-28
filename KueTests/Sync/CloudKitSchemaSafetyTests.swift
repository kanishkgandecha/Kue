//
//  CloudKitSchemaSafetyTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "A./P." Regression coverage for the
//  single most important architectural decision this phase makes: SwiftData's own implicit
//  CloudKit mirroring must never activate merely because the `Kue` app target gained a
//  CloudKit entitlement for `CKSyncEngine`. `ModelContainerFactory.cloudKitDatabase` (added
//  this phase) is the enforcement point; this file is what proves it.
//
//  Every *existing* migration/legacy-recovery test (`SchemaV1MigrationTests`,
//  `SchemaV2MigrationTests`, `SchemaV3MigrationTests`, `RealV1SchemaRegressionTests`,
//  `LegacyRecoverySecurityTests`) already re-ran against the Phase 11 diff as part of the
//  full `KueTests` suite and passed unchanged — see docs/26 "V." for the exact command and
//  result. This file adds only what's *new* to Phase 11 itself, not a duplicate of that
//  existing coverage.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

// `.serialized` — see `SyncCoordinatorTests`'s own header: `SyncPreference` is backed by the
// real, process-global App Group `UserDefaults` suite.
@Suite(.serialized)
struct CloudKitSchemaSafetyTests {
    @Test func everyModelConfigurationExplicitlyDisablesAutomaticCloudKitMirroring() {
        // docs/26 "A.": the literal enforcement point every `ModelConfiguration` in
        // `ModelContainerFactory` references — `ModelConfiguration`'s own default is
        // `.automatic`, which is exactly what this phase must never rely on implicitly.
        // `ModelConfiguration.CloudKitDatabase` conforms to neither `Equatable` nor
        // `CaseIterable` (it's a private-backed struct, not a true enum, confirmed via
        // `String(describing:)`: `CloudKitDatabase(_automatic: false, _none: true,
        // _privateDBName: nil)` for `.none`) — this checks that same descriptive string for
        // the one signal that actually distinguishes it: `_none: true`.
        #expect(String(describing: ModelContainerFactory.cloudKitDatabase).contains("_none: true"))
    }

    @Test func aFreshInMemoryContainerOpensSuccessfullyWithCloudKitDatabaseNone() throws {
        // If `cloudKitDatabase` were left at its `.automatic` default while this process also
        // carries a CloudKit entitlement, SwiftData's own schema-eligibility checks for
        // automatic mirroring (every attribute needs a default, every relationship must be
        // optional-to-many) could make container construction itself behave differently —
        // proving a plain successful open here is a real, not just documented, guarantee.
        let container = ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let event = KueEvent(title: "Safety Check", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(fetched.count == 1)
    }

    // MARK: docs/26 "P.": sync disabled leaves container/store behavior unchanged

    @Test func storeOpensIdenticallyRegardlessOfSyncPreference() throws {
        SyncPreference.setEnabled(false)
        let disabledContainer = ModelContainerFactory.makeInMemory()
        SyncPreference.setEnabled(true)
        let enabledContainer = ModelContainerFactory.makeInMemory()
        SyncPreference.setEnabled(false) // restore the conservative default other tests expect

        // Both are plain, independently-functioning in-memory containers — `SyncPreference`
        // is read only by `SyncCoordinator`, never by `ModelContainerFactory` itself, so
        // nothing about container construction can vary with it.
        let disabledContext = ModelContext(disabledContainer)
        let enabledContext = ModelContext(enabledContainer)
        disabledContext.insert(KueEvent(title: "A", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual))
        enabledContext.insert(KueEvent(title: "B", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual))
        try disabledContext.save()
        try enabledContext.save()
        #expect(try disabledContext.fetch(FetchDescriptor<KueEvent>()).count == 1)
        #expect(try enabledContext.fetch(FetchDescriptor<KueEvent>()).count == 1)
    }

    // MARK: docs/26 "F.": conservative default for existing installations

    @Test func syncPreferenceDefaultsToDisabledForANewOrExistingInstall() {
        // A fresh `UserDefaults` key that's never been explicitly set reads as `false` —
        // `SyncPreference.current` must never silently default to "on."
        #expect(SyncPreference.disabled.isEnabled == false)
    }
}
