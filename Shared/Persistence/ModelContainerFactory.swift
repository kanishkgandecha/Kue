//
//  ModelContainerFactory.swift
//  Kue
//
//  Centralizes the SwiftData schema/ModelContainer so the app, the widget extension,
//  previews, and tests all build it the same way. Lives in Shared/ (not Kue/) because both
//  the "Kue" app target and the "KueWidget" extension target claim this synchronized group —
//  see docs/03-data-model.md "Shared storage: App Group" and AGENTS.md's Phase 4 note.
//
//  Phase 4: makeDefault()'s store now lives in the App Group container, not the app's
//  private sandbox — one live file both processes open, never a copy or snapshot.
//

import SwiftData
import Foundation

enum ModelContainerFactory {
    /// Must match the App Group entitlement on both the Kue and KueWidget targets.
    static let appGroupIdentifier = "group.com.kanishkgandecha.Kue"

    private static let storeFileName = "Kue.sqlite"

    /// Every `@Model` type Kue persists in V1.
    static let schema = Schema([
        KueEvent.self,
        KueTask.self,
        KueSchedule.self,
        WidgetConfiguration.self,
        WidgetState.self,
        Template.self,
        UserPreference.self,
    ])

    /// The app's real, on-disk store — shared with the widget extension via the App Group
    /// container. Crashes on failure, same as Phase 1–3: a broken store is a real bug the
    /// app shouldn't silently paper over. The widget extension must use
    /// `makeDefaultOrNil()` instead — see docs/13-error-handling.md "Widget refresh failure".
    static func makeDefault() -> ModelContainer {
        do {
            return try makeDefaultThrowing()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// Same store as `makeDefault()`, but reports failure instead of crashing — for the
    /// widget extension, where a broken store must fall back to a placeholder-style entry,
    /// never take down the whole extension process.
    static func makeDefaultOrNil() -> ModelContainer? {
        try? makeDefaultThrowing()
    }

    private static func makeDefaultThrowing() throws -> ModelContainer {
        let url = storeURL()
        migrateLegacyStore(from: legacyApplicationSupportDirectory(), to: url)
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Ephemeral store for unit tests and SwiftUI previews — never touches disk.
    static func makeInMemory() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }

    /// The App Group container's store location. Falls back to the app's own (private,
    /// non-shared) Application Support directory only if the App Group container can't be
    /// resolved at all — e.g. a misconfigured entitlement during development — so the app
    /// still launches instead of crashing outright. In that fallback state the widget
    /// extension cannot see the app's data (it has no access to the app's private
    /// container), which is exactly the "unavailable store" case `makeDefaultOrNil()`'s
    /// caller must handle gracefully.
    static func storeURL() -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return legacyApplicationSupportDirectory().appendingPathComponent(storeFileName)
        }
        return containerURL.appendingPathComponent(storeFileName)
    }

    /// Phase 1–3 stored data at SwiftData's own default location/filename (no explicit
    /// `url:` was passed to `ModelConfiguration`) — this phase is the first to move it into
    /// the App Group container. One-time, best-effort migration: if the new location has no
    /// store yet, look for anything under the legacy Application Support directory whose
    /// name starts with SwiftData's default store filename ("default.store*", covering the
    /// store plus its -wal/-shm sidecar files) and *move* it into place — never copy, per
    /// docs/03-data-model.md "Shared storage: App Group" ("never a main-app-store-plus-
    /// widget-snapshot"). If nothing is found (fresh install, or the exact legacy filename
    /// ever changes), this is a safe no-op — a fresh store at the new location, not silent
    /// loss of anything that was actually there.
    /// Not `private` so tests can inject a throwaway `legacyDirectory`/`newURL` instead of
    /// touching the real Application Support directory.
    static func migrateLegacyStore(from legacyDirectory: URL, to newURL: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: newURL.path) else { return }

        guard let entries = try? fileManager.contentsOfDirectory(atPath: legacyDirectory.path) else { return }
        let legacyStoreFiles = entries.filter { $0.hasPrefix("default.store") }
        guard !legacyStoreFiles.isEmpty else { return }

        try? fileManager.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in legacyStoreFiles {
            let source = legacyDirectory.appendingPathComponent(name)
            let destinationName = name == "default.store" ? newURL.lastPathComponent : name.replacingOccurrences(of: "default.store", with: newURL.lastPathComponent)
            let destination = newURL.deletingLastPathComponent().appendingPathComponent(destinationName)
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func legacyApplicationSupportDirectory() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
    }
}
