//
//  ModelContainerFactoryTests.swift
//  KueTests
//
//  Covers docs/03-data-model.md "Shared storage: App Group" — the store location, the
//  no-copy-no-snapshot sharing mechanism, and the legacy-store migration. Uses throwaway
//  temp directories throughout, never the real App Group container, so tests never touch
//  production app data.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct ModelContainerFactoryTests {

    @Test func storeURLPointsIntoAppGroupContainerWhenAvailable() {
        let url = ModelContainerFactory.storeURL()
        #expect(url.lastPathComponent == "Kue.sqlite")
        // If this session can resolve the App Group at all, the store must live inside it —
        // never the app's own private sandbox, which the widget extension can't see.
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ModelContainerFactory.appGroupIdentifier) {
            #expect(url.path.hasPrefix(container.path))
        }
    }

    /// The actual "app and extension share one live store" mechanism: two independent
    /// `ModelContainer`s opened against the same file URL see each other's writes. This is
    /// the general SwiftData behavior `storeURL()` relies on — the App Group only supplies
    /// *which* URL both processes agree to use.
    @Test func twoContainersAtTheSameURLShareData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KueSharedStoreTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Kue.sqlite")

        let containerA = try ModelContainer(for: ModelContainerFactory.schema, configurations: [ModelConfiguration(schema: ModelContainerFactory.schema, url: storeURL, cloudKitDatabase: .none)])
        let contextA = ModelContext(containerA)
        let event = KueEvent(title: "Shared", eventType: .generic, startDate: .now, estimatedDurationMinutes: 0, source: .manual)
        contextA.insert(event)
        try contextA.save()

        // A second, independent container/context opened at the same URL — standing in for
        // the widget extension's separate process opening the app's store.
        let containerB = try ModelContainer(for: ModelContainerFactory.schema, configurations: [ModelConfiguration(schema: ModelContainerFactory.schema, url: storeURL, cloudKitDatabase: .none)])
        let fetched = try ModelContext(containerB).fetch(FetchDescriptor<KueEvent>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Shared")
    }

    // MARK: - Legacy store migration

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "KueMigrationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func migratesLegacyStoreFilesByMovingNotCopying() throws {
        let legacyDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDir) }
        let newDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: newDir) }

        let legacyStore = legacyDir.appending(path: "default.store")
        let legacyWAL = legacyDir.appending(path: "default.store-wal")
        try Data("db".utf8).write(to: legacyStore)
        try Data("wal".utf8).write(to: legacyWAL)

        let newURL = newDir.appending(path: "Kue.sqlite")
        ModelContainerFactory.migrateLegacyStore(from: legacyDir, to: newURL)

        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(FileManager.default.fileExists(atPath: newDir.appending(path: "Kue.sqlite-wal").path))
        // Moved, not copied — nothing left behind at the old location.
        #expect(!FileManager.default.fileExists(atPath: legacyStore.path))
        #expect(!FileManager.default.fileExists(atPath: legacyWAL.path))
    }

    @Test func migrationIsANoOpWhenNothingLegacyExists() throws {
        let legacyDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDir) }
        let newDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: newDir) }
        let newURL = newDir.appending(path: "Kue.sqlite")

        ModelContainerFactory.migrateLegacyStore(from: legacyDir, to: newURL)

        #expect(!FileManager.default.fileExists(atPath: newURL.path)) // fresh start, not a crash
    }

    @Test func migrationNeverOverwritesAnExistingNewStore() throws {
        let legacyDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDir) }
        let newDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: newDir) }

        try Data("legacy".utf8).write(to: legacyDir.appending(path: "default.store"))
        let newURL = newDir.appending(path: "Kue.sqlite")
        try Data("current".utf8).write(to: newURL)

        ModelContainerFactory.migrateLegacyStore(from: legacyDir, to: newURL)

        #expect(try Data(contentsOf: newURL) == Data("current".utf8)) // untouched
        #expect(FileManager.default.fileExists(atPath: legacyDir.appending(path: "default.store").path)) // legacy left alone too
    }
}
