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
            // Kue 2.0 Phase 4 — requirement 42's missing-event/conflict presentations need one
            // already-linked `KueEvent` present at launch. Triple-gated (isolated store AND
            // the fake-calendar argument AND one of these two specific sub-arguments) the same
            // way `ModelContainerFactory.resetUITestStore` is structurally gated — this seeding
            // call has no code path that can run against the real App Group store: it only
            // executes at all when `ModelContainerFactory.isUITestIsolatedStore` is already
            // true, which is itself only ever set by `KueUITests`.
            Self.seedCalendarFixtureIfNeeded(context: container.mainContext)
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
                    // Kue 2.0 Phase 4 — real EventKit-backed access everywhere else in the
                    // app reads only through `\.calendarProvider` (CalendarEnvironment.swift),
                    // same DI seam as the AI environment above. Launched with
                    // `FakeCalendarProvider.uiTestLaunchArgument` (only ever set by
                    // `KueUITests`), a deterministic in-memory fixture is installed instead —
                    // requirement 43/44: never the real EventKit database in a UI test.
                    .environment(\.calendarProvider, Self.makeCalendarProvider())
                    .modelContainer(container)
            case .failure(let diagnostic):
                StoreOpenFailureView(diagnostic: diagnostic) {
                    openOutcome = ModelContainerFactory.makeDefaultOrDiagnostic()
                }
            }
        }
    }

    /// Kue 2.0 Phase 4 — same "launch-argument-gated fake" shape as
    /// `ModelContainerFactory.isUITestIsolatedStore`, one seam over. `MainActor`-isolated (both
    /// conformers require it), so this is called from `body` rather than stored as a stashed
    /// `let` at `init()` time — SwiftUI `App.init()` isn't guaranteed `@MainActor`.
    @MainActor
    private static func makeCalendarProvider() -> CalendarProviding {
        FakeCalendarProvider.makeFromLaunchArguments() ?? SystemCalendarProvider()
    }

    /// Kue 2.0 Phase 4 — see the call site's own comment above for the full gating argument.
    private static func seedCalendarFixtureIfNeeded(context: ModelContext) {
        guard ModelContainerFactory.isUITestIsolatedStore else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(FakeCalendarProvider.uiTestLaunchArgument) else { return }

        if arguments.contains(FakeCalendarProvider.uiTestPreLinkedMissingArgument) {
            let event = KueEvent(
                title: "Fake Prelinked Missing Event", eventType: .generic, startDate: .now.addingTimeInterval(86_400),
                estimatedDurationMinutes: 30, source: .manual,
                externalCalendarEventIdentifier: "fake-ext-does-not-exist",
                externalCalendarIdentifier: "fake-calendar-home",
                externalCalendarTitle: "Fake Calendar Home",
                externalCalendarLastSyncedAt: .now,
                externalCalendarLastKnownModifiedAt: .now
            )
            context.insert(event)
            try? context.save()
        } else if arguments.contains(FakeCalendarProvider.uiTestPreLinkedConflictArgument) {
            let event = KueEvent(
                title: "Fake Prelinked Conflict Event", eventType: .generic, startDate: .now.addingTimeInterval(86_400),
                estimatedDurationMinutes: 30, source: .manual,
                externalCalendarEventIdentifier: FakeCalendarProvider.conflictEventExternalIdentifier,
                externalCalendarIdentifier: "fake-calendar-home",
                externalCalendarTitle: "Fake Calendar Home",
                externalCalendarLastSyncedAt: .now,
                // Always earlier than the fixture event's `.distantFuture` lastModifiedDate —
                // guaranteed to read as externally modified regardless of real launch timing.
                externalCalendarLastKnownModifiedAt: .now
            )
            context.insert(event)
            try? context.save()
        }
    }
}
