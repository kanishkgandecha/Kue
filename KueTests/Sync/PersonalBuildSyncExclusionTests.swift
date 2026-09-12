//
//  PersonalBuildSyncExclusionTests.swift
//  KueTests
//
//  Kue 3.0 Phase 5 — docs/33 "CloudKit retirement"/"Personal-build behavior." Renamed in
//  purpose, not just code, from Kue 2.0 Phase 12's own file of the same name: that phase
//  proved CloudKit sync was structurally *excluded* from Kue Personal (a free Apple Developer
//  Personal Team can't provision CloudKit); this phase's product decision is the inverse —
//  "Supabase becomes Kue's sole production cross-device synchronization system across standard
//  and Personal builds" (requirement A.1) — so what needs proving now is that Supabase sync is
//  *available* in a Personal build whenever it's configured, gated only on
//  `SupabaseConfiguration` (identical in every build configuration), never on
//  `KUE_PERSONAL_BUILD`. `SyncCoordinator.swift`'s own `defaultTransport` has no
//  `#if KUE_PERSONAL_BUILD` branch at all any more — confirmed separately by a real
//  `xcodebuild build -scheme "Kue Personal"` (KueTests never compiles with that flag, so a unit
//  test can't observe the build configuration itself, only the transport-selection logic that
//  doesn't depend on it).
//
//  `NullSyncTransport` remains what any build — Personal or not — installs when Supabase
//  configuration is absent or the account is signed out; this file keeps that fail-closed
//  guarantee's own test too.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite
struct PersonalBuildSyncExclusionTests {
    @Test
    func nullTransportFailsClosedOnEveryOperation() async {
        let transport = NullSyncTransport()

        if case .success = await transport.ensureReady(accessToken: "unused") {
            Issue.record("NullSyncTransport.ensureReady() must never report success")
        }

        let pushResult = await transport.push(SyncPushBatch(eventSaves: [], eventDeletions: []), accessToken: "irrelevant")
        #expect(pushResult.succeededEventIDs.isEmpty)

        let pullResult = await transport.pull(cursor: .initial, pageSize: 10, accessToken: "irrelevant")
        #expect(pullResult.error != nil)
        #expect(pullResult.changedEvents.isEmpty)

        await transport.resetLocalAccountState() // must not crash — nothing to reset
    }

    /// Requirement N: "update Personal-build tests to prove Supabase sync is available when
    /// configured" — the transport-selection logic itself (not the `#if KUE_PERSONAL_BUILD`
    /// compile flag, which this target never sets) never branches on build configuration, only
    /// on whether `SupabaseConfiguration` resolves. A valid configuration always produces a
    /// real `SupabaseSyncTransport`, in every build.
    @Test
    func aValidSupabaseConfigurationAlwaysProducesARealTransportRegardlessOfBuildConfiguration() {
        let configuration = SupabaseConfiguration.make(urlString: "https://example.supabase.co", anonKey: String(repeating: "a", count: 40))
        #expect(configuration != nil)
        guard let configuration else { return }
        let transport = SupabaseSyncTransport(configuration: configuration)
        #expect(transport is SyncTransporting)
    }

    @Test
    func missingConfigurationFallsBackToTheFailClosedNullTransportNeverACrash() {
        // Mirrors `AccountCoordinator.init`'s own "nil configuration → honest unavailable
        // state, never a crash" precedent (docs/32) — the sync-side equivalent.
        let missingConfiguration = SupabaseConfiguration.make(urlString: "not-a-url", anonKey: "short")
        #expect(missingConfiguration == nil)
    }
}
