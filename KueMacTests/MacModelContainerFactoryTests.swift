//
//  MacModelContainerFactoryTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 — proves the Mac-specific pieces of `ModelContainerFactory` (Shared/):
//  store location, CloudKit-free configuration, container creation, and close/reopen
//  durability. The underlying schema/migration-plan wiring itself is already exhaustively
//  proven by `KueTests/Migrations/` against the exact same `ModelContainerFactory` — this
//  file doesn't re-prove that, only what's actually different for this platform.
//
//  All four `KueMacTests` files share this one `@Suite(.serialized)` type (declared here,
//  extended in the other three) rather than four separate suites — Swift Testing's default
//  concurrency runs *different* suites in parallel with each other even when each is
//  individually `.serialized`, and doing that here reliably crashed (`SwiftData/
//  BackingData.swift:835: "This model instance was destroyed by calling ModelContext.reset"`)
//  — several concurrently-alive in-memory `ModelContainer`s racing inside one process, a
//  genuine macOS-SDK SwiftData concurrency issue, confirmed absent both in isolation (every
//  test here passes alone) and on iOS's own equivalent `KueTests` (which never hits this,
//  and already runs many suites full of `makeInMemory()` calls — under `-parallel-testing-
//  enabled NO`, the *outer* xcodebuild/simulator-clone parallelism, a different mechanism
//  from Swift Testing's own intra-process suite concurrency this file addresses). One
//  `.serialized` suite is the reliable fix at this scale; see docs/29 "Testing."
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

@Suite(.serialized)
@MainActor
struct KueMacAllTests {
    @Test func macStoreURLLivesUnderApplicationSupportNeverAnAppGroupContainer() {
        let url = ModelContainerFactory.storeURL()
        #expect(url.path.contains("Application Support"))
        #expect(url.path.contains("/Kue/"))
        // Structural proof, not just a naming convention: the App Group container path (were
        // one ever reachable on this sandboxed, App-Group-free Mac target) would contain
        // "group.com.kanishkgandecha.Kue" — this must never appear in the Mac store path.
        #expect(!url.path.contains(ModelContainerFactory.appGroupIdentifier))
    }

    // Kue 2.0 Phase 11's "never let SwiftData's automatic CloudKit mirroring turn on" rule
    // (every `ModelConfiguration` passes the same shared `ModelContainerFactory
    // .cloudKitDatabase` constant) holds on Mac too — visible directly in
    // `ModelContainerFactory.swift` itself, since this one factory is reused unmodified.
    // `ModelConfiguration.CloudKitDatabase` doesn't conform to `Equatable` on this SDK, so
    // there's no useful runtime assertion to add beyond that structural fact; every
    // container-creation test above already proves the constant is actually used without
    // crashing.

    @Test func makeInMemoryProducesAnIsolatedUsableContainer() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        context.insert(MacTestSupport.makeFixtureEvent())
        #expect((try? context.save()) != nil)
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.count == 1)
    }

    @Test func twoInMemoryContainersNeverShareData() {
        let first = ModelContainerFactory.makeInMemory()
        let second = ModelContainerFactory.makeInMemory()
        first.mainContext.insert(MacTestSupport.makeFixtureEvent(title: "Only in first"))
        try? first.mainContext.save()
        #expect((try? second.mainContext.fetch(FetchDescriptor<KueEvent>()))?.isEmpty == true)
    }

    @Test func aWrittenEventSurvivesAnIndependentCloseAndReopen() throws {
        let url = MacTestSupport.makeTemporaryStoreURL()
        defer { MacTestSupport.removeStore(at: url) }

        let eventID: UUID
        do {
            let container = try ModelContainerFactory.openThroughMigrationPlan(at: url)
            let event = MacTestSupport.makeFixtureEvent(title: "Durable Mac Event")
            eventID = event.id
            container.mainContext.insert(event)
            try container.mainContext.save()
        }

        // A genuinely independent second container at the same URL — not the same in-memory
        // session — proves the write is actually durable on disk, not just visible while the
        // first container happened to still be alive.
        let reopened = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        let events = try reopened.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID }))
        #expect(events.count == 1)
        #expect(events.first?.title == "Durable Mac Event")
    }

    @Test func openingAGenuinelyUnreadableStoreReportsADiagnosticRatherThanDeletingAnything() throws {
        let url = MacTestSupport.makeTemporaryStoreURL()
        defer { MacTestSupport.removeStore(at: url) }
        // Not a valid SQLite file at all — a store-open failure a real disk-corruption case
        // would also produce.
        try Data("not a real sqlite store".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            try ModelContainerFactory.openThroughMigrationPlan(at: url)
        }
        // Requirement 9, carried over from Kue 2.0 Phase 1: a failed open must never delete
        // or rewrite the file it couldn't open.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let bytesAfter = try Data(contentsOf: url)
        #expect(String(decoding: bytesAfter, as: UTF8.self) == "not a real sqlite store")
    }
}
