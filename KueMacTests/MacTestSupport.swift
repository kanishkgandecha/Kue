//
//  MacTestSupport.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 — mirrors `KueTests/Migrations/MigrationTestSupport.swift`'s own
//  `makeTemporaryStoreURL()`/`removeStore(at:)` pattern: every test store here lives at a
//  throwaway temp location, never `ModelContainerFactory.storeURL()` — no test in this
//  target ever touches this Mac's real `~/Library/Application Support/Kue/` store.
//

import Foundation
import SwiftData
@testable import KueMac

enum MacTestSupport {
    static func makeTemporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KueMacTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Kue.sqlite")
    }

    static func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Kue 3.0 Phase 1 — a confirmed macOS-SDK SwiftData issue (see `KueMacAllTests`' own
    /// header in `MacModelContainerFactoryTests.swift`): several `ModelContainerFactory
    /// .makeInMemory()` containers alive at once in one process reliably crashed with
    /// `SwiftData/BackingData.swift:835: "This model instance was destroyed by calling
    /// ModelContext.reset"` — reproduced in isolation (every affected test passes run alone),
    /// absent on iOS's own equivalent `KueTests` (which uses `makeInMemory()` in hundreds of
    /// tests without issue), and absent from every test here that already used a real on-disk
    /// temp store instead. This is that same on-disk substitute, used everywhere this test
    /// target would otherwise have called `makeInMemory()` — the code under test (`Shared/`)
    /// behaves identically against either storage kind; only the test harness's own container
    /// construction changes. Callers should `removeStore(at:)` when done (a leaked temp file
    /// is harmless, matching `MigrationTestSupport`'s own precedent).
    static func makeTestContainer() -> ModelContainer {
        let url = makeTemporaryStoreURL()
        do {
            return try ModelContainerFactory.openThroughMigrationPlan(at: url)
        } catch {
            fatalError("Could not create Mac test container: \(error)")
        }
    }

    /// A minimal, deterministic fixture event — reused across several test files here so
    /// each one doesn't hand-roll its own slightly different `KueEvent` literal.
    static func makeFixtureEvent(
        title: String = "Fixture Event",
        eventType: EventType = .exam,
        startDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> KueEvent {
        KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            estimatedDurationMinutes: 60,
            source: .manual
        )
    }
}
