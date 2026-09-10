//
//  MacBackupInteropTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 — proves `.kuebackup` round-trips through the exact same `BackupCoder`/
//  `BackupPayload`/`BackupRestoreService` (Shared/) the iPhone app uses, invoked from the
//  `KueMac` module. This is proof-by-shared-code (one codec, two module names), not two
//  independently-built decoders that happen to agree — the strongest interoperability
//  guarantee available without a real device-exported fixture file on hand in this
//  environment; see docs/29 "Backup interoperability" for what remains a manual check.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all four files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    @Test func exportedDataDecodesAndValidatesUnderTheSharedCoder() throws {
        let container = MacTestSupport.makeTestContainer()
        container.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Exported From Mac"))
        try container.mainContext.save()

        let data = try BackupCoder.exportData(context: container.mainContext)
        let (envelope, payload) = try BackupCoder.decodeAndValidate(data)
        #expect(envelope.formatVersion == BackupFormat.currentVersion)
        #expect(payload.events.contains { $0.title == "Exported From Mac" })
    }

    @Test func aBackupExportedFromOneMacStoreRestoresIntoAFreshOne() async throws {
        let source = MacTestSupport.makeTestContainer()
        source.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Move Me"))
        try source.mainContext.save()
        let data = try BackupCoder.exportData(context: source.mainContext)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = MacTestSupport.makeTestContainer()
        let summary = try await BackupRestoreService.restore(payload: payload, context: destination.mainContext)
        #expect(summary.eventsInserted == 1)
        let restored = try destination.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(restored.first?.title == "Move Me")
    }

    @Test func restoringTwiceNeverDuplicatesTheSameEvent() async throws {
        let source = MacTestSupport.makeTestContainer()
        source.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Once Only"))
        try source.mainContext.save()
        let data = try BackupCoder.exportData(context: source.mainContext)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = MacTestSupport.makeTestContainer()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination.mainContext)
        let second = try await BackupRestoreService.restore(payload: payload, context: destination.mainContext)
        #expect(second.eventsInserted == 0)
        let allEvents = try destination.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(allEvents.count == 1)
    }

    @Test func existingEventsSurviveAMergeRestoreRatherThanBeingReplaced() async throws {
        let destination = MacTestSupport.makeTestContainer()
        destination.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Already Here"))
        try destination.mainContext.save()

        let source = MacTestSupport.makeTestContainer()
        source.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Incoming"))
        try source.mainContext.save()
        let data = try BackupCoder.exportData(context: source.mainContext)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        _ = try await BackupRestoreService.restore(payload: payload, context: destination.mainContext)
        let titles = try destination.mainContext.fetch(FetchDescriptor<KueEvent>()).map(\.title)
        #expect(titles.contains("Already Here"))
        #expect(titles.contains("Incoming"))
    }

    @Test func aTamperedBackupIsRejectedBeforeTouchingAnyStore() {
        // A named `container` binding, not an anonymous temporary — `ModelContext` doesn't
        // keep its own strong reference to the `ModelContainer` that vended it, so a container
        // built and discarded in the same expression (`makeTestContainer().mainContext`) could
        // be deallocated out from under the context it just handed back.
        let container = MacTestSupport.makeTestContainer()
        var data = (try? BackupCoder.exportData(context: container.mainContext)) ?? Data()
        data.append(contentsOf: [0x00])
        #expect(throws: BackupError.self) {
            _ = try BackupCoder.decodeAndValidate(data)
        }
    }

    @Test func garbageDataIsRejectedAsNotABackupFile() {
        let data = Data("definitely not json".utf8)
        #expect(throws: (any Error).self) {
            _ = try BackupCoder.decodeAndValidate(data)
        }
    }
}
