//
//  KueApp.swift
//  Kue
//
//  Created by Kanishk Gandecha on 25/08/26.
//

import SwiftUI
import SwiftData

@main
struct KueApp: App {
    /// Kue 2.0 Phase 1 — replaces the old `let modelContainer: ModelContainer =
    /// ModelContainerFactory.makeDefault()` (a hard crash on failure) with the diagnostic
    /// path: `@State` so a failed open can be retried in place, from `StoreOpenFailureView`,
    /// without relaunching the app.
    @State private var openOutcome: ModelContainerOpenOutcome

    /// docs/08-notifications.md "Replenishment" / docs/04-event-types.md "Reconciliation" —
    /// registering the launch handler must happen before the app finishes launching, which
    /// for a SwiftUI `App` means here, in `init()`, not later in `.task`/`onAppear`.
    /// Registering the same identifier twice in one process crashes, so this must run
    /// exactly once — `init()` on `@main` guarantees that.
    ///
    /// Scoping note: if the *initial* open fails, this registers a handler that always
    /// completes as a no-op for the rest of this process's lifetime, even if the user later
    /// taps "Try Again" and the store opens successfully — re-targeting an already-registered
    /// `BGTaskScheduler` handler at a container that didn't exist yet at registration time
    /// isn't possible without an extra layer of mutable indirection this narrow an edge case
    /// doesn't warrant. The very next app launch (a fresh process) registers correctly
    /// against whatever `makeDefaultOrDiagnostic()` resolves to at that point; only
    /// background-refresh timing is affected, never data access, which the "Try Again" button
    /// itself already restores immediately.
    init() {
        let outcome = ModelContainerFactory.makeDefaultOrDiagnostic()
        _openOutcome = State(initialValue: outcome)

        if case .success(let container) = outcome {
            SystemBackgroundTaskScheduler.shared.register(identifier: BackgroundRefreshTask.identifier) { task in
                Task { @MainActor in
                    await BackgroundRefreshHandler.handle(
                        task,
                        context: container.mainContext,
                        scheduler: SystemNotificationScheduler.shared,
                        backgroundScheduler: SystemBackgroundTaskScheduler.shared
                    )
                }
            }
        } else {
            SystemBackgroundTaskScheduler.shared.register(identifier: BackgroundRefreshTask.identifier) { task in
                task.setTaskCompleted(success: false)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch openOutcome {
            case .success(let container):
                HomeView()
                    // Real, on-device-only implementations — see docs/06-ai-layer.md "Parser
                    // runtime & credentials". Everywhere else in the app reads these only
                    // through the `NLParsing`/`AIAvailabilityChecking` environment seam
                    // (AIEnvironment.swift), so KueTests can swap in fixture-backed fakes and
                    // never reach this line.
                    .environment(\.nlParser, FoundationModelsParser())
                    .environment(\.aiAvailabilityChecker, SystemAIAvailabilityChecker())
                    .modelContainer(container)
            case .failure(let diagnostic):
                StoreOpenFailureView(diagnostic: diagnostic) {
                    openOutcome = ModelContainerFactory.makeDefaultOrDiagnostic()
                }
            }
        }
    }
}
