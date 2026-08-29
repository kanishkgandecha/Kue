//
//  PersonalBuildSyncExclusionTests.swift
//  KueTests
//
//  Kue 2.0 Phase 12 — docs/27. `NullCloudSyncTransport`/`NullCloudAccountProvider` are the
//  types `SyncCoordinator.defaultTransport`/`defaultAccountProvider` install in place of
//  `SystemCloudSyncTransport`/`SystemCloudAccountProvider` when compiled with
//  `KUE_PERSONAL_BUILD` (Kue/Services/Sync/SyncCoordinator.swift) — that selection itself is a
//  compile-time `#if` only reachable in the "Kue Personal" scheme's "Debug-Personal"
//  configuration (verified separately by a real `xcodebuild build -scheme "Kue Personal"` and
//  entitlement inspection, not by a unit test — KueTests never compiles with that flag, so a
//  test can't observe the `#if` branch itself). What *is* testable here, and matters just as
//  much: that the fallback types this build depends on actually behave safely — fail closed,
//  never a real network/CloudKit call, never a crash — so a Personal build's `SyncCoordinator`
//  degrades cleanly rather than merely "happening not to have been exercised."
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite
struct PersonalBuildSyncExclusionTests {
    @Test
    func nullTransportFailsClosedOnEveryOperation() async {
        let transport = NullCloudSyncTransport()

        if case .success = await transport.ensureZoneExists() {
            Issue.record("NullCloudSyncTransport.ensureZoneExists() must never report success")
        }

        let sendResult = await transport.send(eventSaves: [], eventDeletions: [], exclusionSaves: [], exclusionDeletions: [])
        #expect(sendResult.succeededEventIDs.isEmpty)
        #expect(sendResult.succeededExclusionIDs.isEmpty)

        let fetchResult = await transport.fetchChanges()
        #expect(fetchResult.error != nil)
        #expect(fetchResult.changedEvents.isEmpty)

        await transport.resetEngineState() // must not crash — nothing to reset
    }

    @Test
    func nullAccountProviderReportsNoAccount() async {
        let provider = NullCloudAccountProvider()
        #expect(await provider.currentState() == .noAccount)
        #expect(await provider.currentAccountFingerprint() == nil)
    }
}
