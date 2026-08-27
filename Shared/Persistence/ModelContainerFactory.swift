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
//  PRODUCTION INCIDENT (2026-08-27) — a genuine pre-migration App Group store failed to open
//  with NSCocoaErrorDomain 134504, "Cannot use staged migration with an unknown model
//  version," even after `KueSchemaV1` was corrected to exactly match that store's real,
//  on-disk structure (see `KueSchemaV1.swift`'s header for the full incident and root-cause
//  analysis). Bisection against a copy of the real store proved SwiftData's staged/custom
//  migration path requires an *exact* recorded version-hash match and will not fall back to
//  structural inference — but a **plain**, migration-plan-less `ModelContainer` open (which
//  SwiftData always performs with `NSMigratePersistentStoresAutomaticallyOption`/
//  `NSInferMappingModelAutomaticallyOption` enabled) reconciles the store purely structurally,
//  column-by-column, regardless of hash, and rewrites the store's own `Z_METADATA` to match
//  the schema it was just opened with in the process.
//
//  HARDENING (2026-08-28) — the first version of this fix (above) invoked its recovery
//  fallback after *any* staged-`ModelContainer` failure, with no confirmation the failing
//  store was actually a genuine V1.0 store, and no backup before mutating it. This version is
//  the reviewed, approved one — `openThroughMigrationPlan(at:)` now only ever attempts
//  recovery when *all* of the following hold, in order:
//   1. The store's own persistent-store metadata — read via
//      `NSPersistentStoreCoordinator.metadataForPersistentStore(ofType:at:options:)`, which
//      never opens the store or attempts any migration — matches `VerifiedV1StoreSignature`
//      *exactly* (store type, version identifiers, and the precise 7-entity hash set). Any
//      read failure, or any non-exact match (corrupted store, wrong version, an already-
//      migrated V2/V3 store, an unrelated store, a merely structurally-similar one), rethrows
//      the *original* staged-migration error untouched — recovery is never attempted.
//   2. A SQLite-safe backup (`LegacyStoreBackup`, built on `SQLiteBackup`'s Online Backup API
//      — never a raw file copy of a live database) is created at a fresh, collision-proof path
//      before anything mutates the store. If the backup itself can't be created, recovery is
//      not attempted at all.
//   3. `recognizeAsV1IfPossible(at:)` — the same plain, no-migration-plan open as before —
//      re-stamps the store's metadata to an exact hash match, if the store's actual on-disk
//      shape really is V1-shaped.
//   4. `validateRecoveredStoreAndReopen(at:)` fetches every modeled entity type, checks every
//      parent-pointing relationship resolves, performs a real post-migration write, and closes
//      and reopens the store in an independent `ModelContainer` instance to prove the write
//      (and every pre-existing row) is durably on disk — not just visible within one session.
//  If *any* of steps 3-4 fails, every container involved is released, the backup is restored
//  in full (SQLite-safe, both directions), and the *original* staged-migration error is what's
//  surfaced — never a confusing secondary one, and never a store left in a worse state than it
//  started in.
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
import CoreData

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
        return try openThroughMigrationPlan(at: url)
    }

    /// The one place `schema`/`migrationPlan` are actually handed to `ModelContainer` against
    /// a real, on-disk `url` — both `makeDefaultThrowing()` (the real App Group store) and
    /// `RealStoreCopyVerification` (a throwaway copy) call this, so both exercise the exact
    /// same recovery fallback. See this file's header ("HARDENING") for the full, reviewed
    /// mechanism and every requirement it satisfies.
    static func openThroughMigrationPlan(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: url)
        // A verified historical V1 store is special-cased *before* the first container open.
        // Even a failed staged migration is allowed to modify SQLite/Core Data metadata, so
        // waiting for that failure before taking the backup would be too late. All other
        // stores—including current V2/V3 stores—stay on the ordinary one-open path below.
        guard shouldAttemptLegacyRecovery(at: url) else {
            return try ModelContainer(
                for: schema,
                migrationPlan: migrationPlan,
                configurations: [configuration]
            )
        }

        // No mutating open of a verified legacy store may happen without a complete SQLite
        // snapshot already in hand. A backup failure is therefore surfaced directly.
        let backup = try LegacyStoreBackup.create(for: url)

        do {
            // Preserve the normal staged path when possible. For the incident store this is
            // expected to throw because its historical hash is not reproduced by the frozen
            // Swift declaration, but the attempt is now protected by `backup`.
            do {
                let opened = try ModelContainer(
                    for: schema,
                    migrationPlan: migrationPlan,
                    configurations: [configuration]
                )
                backup.discard()
                return opened
            } catch let originalStagedError {
                do {
                    try recognizeAsV1IfPossible(at: url)
                    let recovered = try validateRecoveredStoreAndReopen(at: url)
                    backup.discard()
                    return recovered
                } catch {
                    // Restore below, then preserve the original staged-migration diagnostic.
                    try backup.restore()
                    throw originalStagedError
                }
            }
        } catch {
            // If restoration itself failed, `backup` is deliberately retained beside the
            // store for manual recovery and the restore error is surfaced instead of being
            // silently swallowed.
            throw error
        }
    }

    /// Requirement 1/2/3/5 — the *only* gate deciding whether `openThroughMigrationPlan(at:)`
    /// is allowed to attempt anything mutating. Reads the store's own persistent-store
    /// metadata via `NSPersistentStoreCoordinator.metadataForPersistentStore(ofType:at:
    /// options:)`, which never opens the store or attempts any migration — a pure, read-only
    /// probe — and compares it against `VerifiedV1StoreSignature` *exactly*. Fails closed:
    /// a missing file, an unreadable/corrupted store, or any non-exact-match metadata (wrong
    /// store type, wrong version identifiers, a differently-shaped or partially-migrated
    /// entity-hash set) all return `false`, never `true`.
    private static func shouldAttemptLegacyRecovery(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: nil
        ) else { return false }
        return VerifiedV1StoreSignature.matches(metadata: metadata)
    }

    /// See this file's header ("HARDENING") for the full mechanism. Throws (doing nothing
    /// further to the store beyond whatever this one open attempt itself performed) if the
    /// store isn't actually V1-shaped — the only case this is silent-no-op-safe to attempt,
    /// since a plain open with `NSInferMappingModelAutomatically` either succeeds because the
    /// shapes genuinely match, or fails outright. Only ever reached after
    /// `shouldAttemptLegacyRecovery(at:)` has already confirmed the store's *metadata* claims
    /// to be V1 — this is what confirms its actual *structure* agrees.
    private static func recognizeAsV1IfPossible(at url: URL) throws {
        #if DEBUG
        LegacyRecoveryTestHooks.recognitionAttempted?()
        if LegacyRecoveryTestHooks.forceRecognitionFailure {
            throw LegacyRecoveryTestHooks.InjectedFailure.recognition
        }
        #endif
        let v1Schema = Schema(versionedSchema: KueSchemaV1.self)
        let v1Configuration = ModelConfiguration(schema: v1Schema, url: url)
        _ = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
    }

    /// Requirement 9 — validates the store `recognizeAsV1IfPossible(at:)` just re-stamped, and
    /// only returns a `ModelContainer` if every check below passes:
    ///  - every modeled entity type fetches without throwing ("every field")
    ///  - every parent-pointing relationship (`KueTask`/`KueSchedule`/`WidgetConfiguration`/
    ///    `WidgetState` → their owning `KueEvent`) actually resolves back to that event
    ///    ("every relationship")
    ///  - a real write survives a save ("post-migration write")
    ///  - that write, and the original event count, both survive an independent close-and-
    ///    reopen — not just remaining visible within the same in-memory session
    /// ("expected event count" here means "unchanged by this whole recovery process," which is
    /// the only meaning that makes sense for a *generic* recovery path used across however many
    /// real events a given store happens to contain — not a hardcoded number specific to any
    /// one incident.)
    private static func validateRecoveredStoreAndReopen(at url: URL) throws -> ModelContainer {
        #if DEBUG
        LegacyRecoveryTestHooks.validationAttempted?()
        if LegacyRecoveryTestHooks.forceValidationFailure {
            throw LegacyRecoveryTestHooks.InjectedFailure.validation
        }
        #endif

        let originalEventCount: Int
        let marker = UUID()
        do {
            let configuration = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
            let context = container.mainContext

            let events = try context.fetch(FetchDescriptor<KueEvent>())
            originalEventCount = events.count
            _ = try context.fetch(FetchDescriptor<KueTask>())
            _ = try context.fetch(FetchDescriptor<KueSchedule>())
            _ = try context.fetch(FetchDescriptor<WidgetConfiguration>())
            _ = try context.fetch(FetchDescriptor<WidgetState>())
            _ = try context.fetch(FetchDescriptor<Template>())
            _ = try context.fetch(FetchDescriptor<UserPreference>())

            for event in events {
                for task in event.tasks {
                    guard task.event?.id == event.id else { throw LegacyRecoveryValidationError.relationshipMismatch }
                }
                if let schedule = event.schedule {
                    guard schedule.event?.id == event.id else { throw LegacyRecoveryValidationError.relationshipMismatch }
                }
                if let widgetConfiguration = event.widgetConfiguration {
                    guard widgetConfiguration.event?.id == event.id else { throw LegacyRecoveryValidationError.relationshipMismatch }
                }
                if let widgetState = event.widgetState {
                    guard widgetState.event?.id == event.id else { throw LegacyRecoveryValidationError.relationshipMismatch }
                }
            }

            context.insert(KueEvent(
                id: marker, title: "", eventType: .generic, startDate: .now,
                estimatedDurationMinutes: 0, source: .manual
            ))
            try context.save()
            // `container`/`context` fall out of scope at the end of this `do` block — genuinely
            // released, not merely unused, before the independent reopen below.
        }

        #if DEBUG
        if LegacyRecoveryTestHooks.forceReopenFailure {
            throw LegacyRecoveryTestHooks.InjectedFailure.reopen
        }
        #endif

        let reopenConfiguration = ModelConfiguration(schema: schema, url: url)
        let reopened = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [reopenConfiguration])
        let reopenedContext = reopened.mainContext

        guard let persistedMarker = try reopenedContext.fetch(
            FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == marker })
        ).first else {
            throw LegacyRecoveryValidationError.postMigrationWriteDidNotPersist
        }
        // Validation shouldn't leave a permanent synthetic row behind.
        reopenedContext.delete(persistedMarker)
        try reopenedContext.save()

        let finalCount = try reopenedContext.fetch(FetchDescriptor<KueEvent>()).count
        guard finalCount == originalEventCount else { throw LegacyRecoveryValidationError.eventCountChanged }

        return reopened
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

// MARK: - Legacy recovery validation (requirement 9)

enum LegacyRecoveryValidationError: LocalizedError {
    case relationshipMismatch
    case postMigrationWriteDidNotPersist
    case eventCountChanged

    var errorDescription: String? {
        switch self {
        case .relationshipMismatch: return "A recovered event's relationship didn't resolve back to it."
        case .postMigrationWriteDidNotPersist: return "A write made after legacy recovery didn't survive a reopen."
        case .eventCountChanged: return "The event count changed unexpectedly during legacy recovery."
        }
    }
}

#if DEBUG
/// Requirement 10/11 — test-only observation/injection seams for
/// `ModelContainerFactory`'s legacy-recovery mechanism. Compiled only into Debug builds (every
/// `KueTests`/`KueUITests` run uses the Debug configuration), and touched only by tests
/// (`@testable import Kue`) — production code paths only ever *check* these, never set them,
/// so they're inert in every real launch.
enum LegacyRecoveryTestHooks {
    enum InjectedFailure: Error {
        case recognition
        case validation
        case reopen
    }

    /// Set by a test to observe whether `recognizeAsV1IfPossible(at:)` was actually invoked —
    /// requirement 10's negative tests assert this stays `nil`-triggered (never called) for
    /// every rejected store shape, rather than inferring non-invocation from side effects.
    static var recognitionAttempted: (() -> Void)?
    static var validationAttempted: (() -> Void)?

    /// Requirement 11 — force a failure at each of the three post-backup mutation stages in
    /// turn, so a test can deterministically prove `openThroughMigrationPlan(at:)` restores
    /// the backup and surfaces the *original* error at every one of them, not just whichever
    /// one happens to fail naturally.
    static var forceRecognitionFailure = false
    static var forceValidationFailure = false
    static var forceReopenFailure = false

    /// Resets every hook — call from a test's `defer` so one test's injection can never leak
    /// into the next.
    static func reset() {
        recognitionAttempted = nil
        validationAttempted = nil
        forceRecognitionFailure = false
        forceValidationFailure = false
        forceReopenFailure = false
    }
}
#endif
