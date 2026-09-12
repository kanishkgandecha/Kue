//
//  KueMacApp.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — Native macOS Application Foundation (docs/29). Entry point for the
//  `KueMac` target — a genuine native macOS app, not a Catalyst wrapper. Shares every domain
//  model/service with the iPhone app via `Shared/` (see that folder's own header) and reuses
//  `ModelContainerFactory` unmodified except for its one macOS-specific store-location branch
//  (`storeURL()`'s `#if os(macOS)`) — no second container-construction path, no duplicated
//  schema/migration wiring (requirement 4's "consistently").
//
//  Personal-build guarantee: `KueMac.entitlements` carries `com.apple.security.app-sandbox` +
//  `com.apple.security.files.user-selected.read-write` only — no App Group, no iCloud/
//  CloudKit capability, in every configuration (Debug/Release/Debug-Personal alike). This app
//  never constructs a `CKContainer` and never touches the iPhone's real App Group store; the
//  only way data crosses platforms is an explicit `.kuebackup` export/import (see
//  `BackupSettingsSection.swift`). See docs/29 "Personal-build guarantees."
//

import SwiftUI
import SwiftData

@main
struct KueMacApp: App {
    let container: ModelContainer
    @State private var storeOpenError: StoreOpenDiagnostic?
    @State private var appState = MacAppState()
    /// Kue 3.0 Phase 4 — docs/32 "Architecture." Same instance for both the `WindowGroup` and
    /// `Settings` scenes below — Mac's own Profile destination lives in Settings, but other
    /// windows may want to read `state` too later, so this isn't scoped to just one scene.
    @State private var accountCoordinator = Self.makeAccountCoordinator()

    init() {
        // Kue 3.0 Phase 5 — same "real transport never runs under KueMacUITests" seam
        // `KueApp.init()`'s own `SyncCoordinator.makeFromLaunchArguments()` call already
        // establishes for iPhone.
        if let fakeSyncCoordinator = SyncCoordinator.makeFromLaunchArguments() {
            SyncCoordinator.shared = fakeSyncCoordinator
        }
        switch ModelContainerFactory.makeDefaultOrDiagnostic() {
        case .success(let container):
            self.container = container
        case .failure(let diagnostic):
            // Kue 2.0 Phase 1's own recoverable-diagnostic path (`StoreOpenFailureView`,
            // iOS-only) doesn't compile into this target — Mac gets its own minimal
            // equivalent (`MacStoreOpenFailureView`) rather than crashing outright. Building
            // *some* container here (in-memory) keeps `@main`'s stored property satisfiable;
            // the real diagnostic is what actually renders, in `body` below, and it is never
            // silently discarded.
            self.container = ModelContainerFactory.makeInMemory()
            _storeOpenError = State(initialValue: diagnostic)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let storeOpenError {
                    MacStoreOpenFailureView(diagnostic: storeOpenError)
                } else {
                    RootSplitView(appState: appState)
                        .task {
                            _ = EventStatusEngine.sweep(context: container.mainContext)
                            _ = OccurrenceReconciliationService.replenishAll(context: container.mainContext)
                        }
                        // Kue 3.0 Phase 4 — never blocks the window from opening; local data
                        // (the two sweeps above) is already independent of this.
                        .task { await accountCoordinator.restoreSession() }
                        // Kue 3.0 Phase 5 — docs/33 "Architecture": the same launch-trigger
                        // reasoning as `accountCoordinator.restoreSession()` immediately
                        // above — `SyncCoordinator.sync` itself already no-ops instantly
                        // unless sync is on, signed in, and past the first-sync decision.
                        .task { await SyncCoordinator.shared.sync(context: container.mainContext, account: accountCoordinator) }
                        .onChange(of: accountCoordinator.state) { _, newState in
                            if case .signedIn = newState {
                                Task { await SyncCoordinator.shared.sync(context: container.mainContext, account: accountCoordinator) }
                            }
                        }
                }
            }
            .frame(minWidth: 760, minHeight: 480)
            .environment(\.calendarProvider, Self.makeCalendarProvider())
            .environment(accountCoordinator)
        }
        .modelContainer(container)
        .commands {
            KueMacCommands(appState: appState)
        }

        Settings {
            MacSettingsView(appState: appState)
                .modelContainer(container)
                .environment(\.calendarProvider, Self.makeCalendarProvider())
                .environment(accountCoordinator)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - Calendar (Kue 3.0 Phase 1 cleanup — see docs/29 "Calendar")

    /// Kue 3.0 Phase 1 cleanup — same real-vs-fake gate `Kue/KueApp.swift`'s own
    /// `makeCalendarProvider()` already uses; `SystemCalendarProvider` (Shared/, moved here
    /// unmodified from `Kue/Services/Calendar/`) is entirely EventKit, which is fully
    /// available on macOS — confirmed by a real `xcodebuild build`, not assumed. `KueMac` has
    /// no `KueMacUITests` Calendar coverage yet (see docs/29), so this launch-argument gate
    /// is dormant today, kept only for parity with the exact pattern iOS already established.
    private static func makeCalendarProvider() -> CalendarProviding {
        FakeCalendarProvider.makeFromLaunchArguments() ?? SystemCalendarProvider()
    }

    // MARK: - Accounts (Kue 3.0 Phase 4 — docs/32 "Architecture")

    /// Same shape as `Kue/KueApp.swift`'s own `makeAccountCoordinator()` — a separate,
    /// device-local `SystemSecureStore`/session (no App Group on this target, matching this
    /// file's own header's "no cross-platform data path but backup" guarantee).
    private static func makeAccountCoordinator() -> AccountCoordinator {
        let provider: AccountProviding? = FakeAccountProvider.makeFromLaunchArguments()
            ?? SupabaseConfiguration.current.map { SystemAccountProvider(configuration: $0) }
        let secureStore: SecureStoring = ProcessInfo.processInfo.arguments.contains(FakeAccountProvider.uiTestLaunchArgument)
            ? FakeSecureStore()
            : SystemSecureStore.shared
        return AccountCoordinator(provider: provider, secureStore: secureStore)
    }
}
