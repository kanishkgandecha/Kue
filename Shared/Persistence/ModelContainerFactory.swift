//
//  ModelContainerFactory.swift
//  Kue
//
//  Centralizes the SwiftData schema/ModelContainer so the app, the widget extension, the
//  Share Extension, previews, and tests all build it the same way. Lives in Shared/ (not
//  Kue/) because Kue, KueWidget, *and* KueShare all claim this synchronized group — see
//  docs/03-data-model.md "Shared storage: App Group" and AGENTS.md's "Three targets" note.
//
//  Phase 4: makeDefault()'s store lives in the App Group container, not the app's private
//  sandbox — one live file every process opens, never a copy or snapshot.
//
//  Kue 2.0 Phase 1 (SwiftData Migration Foundation, see docs/15-schema-migrations.md):
//  `schema`/`migrationPlan` below are now built from `KueSchemaV1`/`KueMigrationPlan`
//  (Persistence/Migrations/) instead of a bare, unversioned `Schema([...])` literal — every
//  one of `makeDefault()`/`makeDefaultOrNil()`/`makeDefaultOrDiagnostic()`/`makeInMemory()`
//  routes through the same `makeDefaultThrowing()` (or an equivalent explicit construction
//  for `makeInMemory()`), so there is exactly one place all three production targets and
//  every test get their schema/migration wiring from — requirement 4's "consistently."
//
//  Kue 2.0 Phase 3 post-implementation cleanup — UI-test store isolation. `KueUITests` drives
//  the real app (`XCUIApplication`, not `@testable import Kue`), so it can't inject an
//  in-memory container the way `KueTests` does; every UI test previously shared the same real
//  on-disk App Group store across the whole combined suite, and data accumulated by one test
//  class made events created by a *later* class hard to find (buried in Home's lazily-
//  rendered list) — a real flakiness source, not a product defect. `isUITestIsolatedStore`/
//  `uiTestStoreURL()`/`resetUITestStoreIfNeeded()` below fix that: when (and only when) the
//  process was launched with `uiTestLaunchArgument` — set exclusively by each `KueUITests`
//  case's own `XCUIApplication.launchArguments`, never by a normal launch — `storeURL()`
//  resolves to a location entirely outside the App Group container, wiped clean at the start
//  of every single launch. This is a structural safety property, not just a flag check: even
//  if the flag were somehow set unexpectedly, the reset path can only ever delete files under
//  that separate temporary location — it has no code path back to the real App Group store
//  URL, so production data is unreachable from it by construction, not merely "supposed to
//  be." See `AGENTS.md` "Build & test" for how the UI test target wires this in.
//

import SwiftData
import Foundation

enum ModelContainerFactory {
    /// Must match the App Group entitlement on the Kue, KueWidget, and KueShare targets.
    static let appGroupIdentifier = "group.com.kanishkgandecha.Kue"

    private static let storeFileName = "Kue.sqlite"

    /// Set via `XCUIApplication.launchArguments` by every `KueUITests` case, and only there —
    /// a normal app launch (user, widget extension, Share Extension) never passes this, so
    /// `isUITestIsolatedStore` is always `false` outside of UI tests.
    static let uiTestLaunchArgument = "-uiTestIsolatedStore"

    /// `true` only inside a process launched by `XCUIApplication` with `uiTestLaunchArgument`
    /// — i.e. only inside the "Kue" app process when driven by `KueUITests`. Checked once per
    /// access rather than cached, so it stays correct even though `ModelContainerFactory` is a
    /// stateless `enum`.
    static var isUITestIsolatedStore: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestLaunchArgument)
    }

    /// Built from `KueSchemaV3` (Persistence/Migrations/) — the *current* schema version. Do
    /// **not** replace this with a bare `Schema([...])` literal again; that would silently
    /// detach the schema this app opens stores with from the versioned/migratable one
    /// `KueMigrationPlan` describes. Kue 2.0 Phase 4 added `KueSchemaV3` (Calendar-linkage
    /// fields) — see docs/18-calendar-integration.md "Migration" and `KueMigrationPlan`'s own
    /// header.
    static let schema = Schema(versionedSchema: KueSchemaV3.self)

    /// `KueSchemaV1` → `KueSchemaV2` → `KueSchemaV3` as of Kue 2.0 Phase 4 — see
    /// `KueMigrationPlan`'s own header for what adding the *next* stage looks like.
    static let migrationPlan: any SchemaMigrationPlan.Type = KueMigrationPlan.self

    /// The app's real, on-disk store — shared with both extensions via the App Group
    /// container. Crashes on failure, same as Phase 1–3: a broken store is a real bug the
    /// app shouldn't silently paper over. Prefer `makeDefaultOrDiagnostic()` from any call
    /// site that can present a recovery UI instead of crashing outright (KueApp does); the
    /// widget/Share Extension must use `makeDefaultOrNil()` instead — see
    /// docs/13-error-handling.md "Widget refresh failure".
    static func makeDefault() -> ModelContainer {
        do {
            return try makeDefaultThrowing()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// Same store as `makeDefault()`, but reports failure instead of crashing — for the
    /// widget extension and Share Extension, where a broken store must degrade gracefully
    /// (a placeholder-style widget entry; an alert + no-op in the Share Extension), never
    /// take down the whole extension process.
    static func makeDefaultOrNil() -> ModelContainer? {
        try? makeDefaultThrowing()
    }

    /// Same store as `makeDefault()`, but never crashes — reports failure as a
    /// `StoreOpenDiagnostic` instead, carrying the store URL and the underlying error, so a
    /// caller that *can* show UI (KueApp) can present a recoverable diagnostic path rather
    /// than a hard crash. Requirement 9: "must never silently delete user data" — nothing on
    /// this path (or anywhere else in this file) ever deletes, resets, or recreates the
    /// store on a failed open; a failed open leaves the on-disk file exactly as it was.
    static func makeDefaultOrDiagnostic() -> ModelContainerOpenOutcome {
        do {
            return .success(try makeDefaultThrowing())
        } catch {
            return .failure(StoreOpenDiagnostic(storeURL: storeURL(), underlyingError: error))
        }
    }

    private static func makeDefaultThrowing() throws -> ModelContainer {
        let url = storeURL()
        if isUITestIsolatedStore {
            // Requirement: "launch with a deterministic isolated test store" — wipe it before
            // every single launch (not just once per suite) so each UI test method starts
            // from a guaranteed-empty store, with no manual simulator erase needed between
            // test classes and no dependence on execution order. `url` here can only ever be
            // `uiTestStoreURL()` (see `storeURL()`), never the real App Group path.
            resetUITestStore(at: url)
        } else {
            migrateLegacyStore(from: legacyApplicationSupportDirectory(), to: url)
        }
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
    }

    /// Ephemeral store for unit tests and SwiftUI previews — never touches disk. Also routed
    /// through `migrationPlan` (a currently-empty stage list is a no-op for a store that was
    /// just created from scratch), so tests exercise the same construction path production
    /// does — requirement 4.
    static func makeInMemory() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
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
        if isUITestIsolatedStore {
            return uiTestStoreURL()
        }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return legacyApplicationSupportDirectory().appendingPathComponent(storeFileName)
        }
        return containerURL.appendingPathComponent(storeFileName)
    }

    /// Entirely outside the App Group container — under the process's own temporary
    /// directory, keyed by `uiTestLaunchArgument` so it can never collide with (or be
    /// confused for) the real store path. A fixed name *within* that isolated location is
    /// fine (not a fresh UUID per launch): `resetUITestStore(at:)` wipes it at the start of
    /// every launch anyway, so nothing ever accumulates across runs, and a fixed, predictable
    /// path keeps this trivially inspectable during development.
    private static func uiTestStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KueUITestStore", isDirectory: true)
            .appendingPathComponent(storeFileName)
    }

    /// Deletes the store (and its `-wal`/`-shm` sidecars) at `url` if present, then ensures
    /// the containing directory exists — called only from `makeDefaultThrowing()`, only when
    /// `isUITestIsolatedStore` is true, only ever on `uiTestStoreURL()`'s own result. Never
    /// touches, and has no way to reach, the real App Group store.
    private static func resetUITestStore(at url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: url.path + suffix)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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

// MARK: - Failure handling (requirement 9: recoverable diagnostic path, never silent data loss)

enum ModelContainerOpenOutcome {
    case success(ModelContainer)
    case failure(StoreOpenDiagnostic)
}

/// Everything a recovery UI needs to show the user something specific and true, never a
/// generic "something went wrong" (docs/13-error-handling.md's own house rule, applied here
/// too) — the store's on-disk location (so support/debugging can find it) and the real
/// underlying `Error` SwiftData reported, not a swallowed one.
struct StoreOpenDiagnostic {
    let storeURL: URL
    let underlyingError: Error

    var errorDescription: String {
        underlyingError.localizedDescription
    }
}
