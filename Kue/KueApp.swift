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
    let modelContainer: ModelContainer = ModelContainerFactory.makeDefault()

    /// docs/08-notifications.md "Replenishment" / docs/04-event-types.md "Reconciliation" —
    /// registering the launch handler must happen before the app finishes launching, which
    /// for a SwiftUI `App` means here, in `init()`, not later in `.task`/`onAppear`.
    /// Registering the same identifier twice in one process crashes, so this must run
    /// exactly once — `init()` on `@main` guarantees that.
    init() {
        let container = modelContainer
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
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                // Real, on-device-only implementations — see docs/06-ai-layer.md "Parser
                // runtime & credentials". Everywhere else in the app reads these only through
                // the `NLParsing`/`AIAvailabilityChecking` environment seam (AIEnvironment.swift),
                // so KueTests can swap in fixture-backed fakes and never reach this line.
                .environment(\.nlParser, FoundationModelsParser())
                .environment(\.aiAvailabilityChecker, SystemAIAvailabilityChecker())
        }
        .modelContainer(modelContainer)
    }
}
