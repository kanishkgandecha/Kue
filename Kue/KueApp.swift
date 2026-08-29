//
//  KueApp.swift
//  Kue
//
//  Created by Kanishk Gandecha on 25/08/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct KueApp: App {
    /// Kue 2.0 Phase 1 — replaces the old `let modelContainer: ModelContainer =
    /// ModelContainerFactory.makeDefault()` (a hard crash on failure) with the diagnostic
    /// path: `@State` so a failed open can be retried in place, from `StoreOpenFailureView`,
    /// without relaunching the app.
    @State private var openOutcome: ModelContainerOpenOutcome

    /// Kue 2.0 Phase 9 — resolved once at launch, not inline in `body`: unlike every other
    /// fake-service factory in this file, `FakeLiveActivityManager` is a stateful reference
    /// type a UI test flow relies on staying identical across navigation (start on event A,
    /// navigate away, come back — the same fake must still remember it). `body` can be
    /// re-evaluated more than once per process (scene reconnection events), and calling
    /// `Self.makeLiveActivityManager()` inline there would silently hand a *fresh*
    /// `FakeLiveActivityManager()` to whatever re-renders after that point, discarding
    /// whichever activity the test had just started. `SystemLiveActivityManager.shared` is
    /// already a singleton so this changes nothing for the production path.
    private let liveActivityManager: LiveActivityManaging = Self.makeLiveActivityManager()

    /// Kue 2.0 Phase 10 — same "resolved once at launch, not inline in `body`" reasoning as
    /// `liveActivityManager` immediately above: `FakeSpotlightIndexer` is stateful, and a UI
    /// test flow (index → verify → remove) needs the identical instance across navigation.
    private let spotlightIndexer: SpotlightIndexing = Self.makeSpotlightIndexer()

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

        // Kue 2.0 Phase 10.1 — docs/25 "K.": register the outcome-follow-up action category
        // and install the delegate that routes those actions, regardless of whether the store
        // opened (mirrors the background-task registration's own "always register, no-op if
        // there's nothing to act on" shape immediately below). Deferred to a `Task` rather
        // than called inline: `UNUserNotificationCenter` access is real system IPC with
        // measurable launch-time cost — a real regression found via `KueUITests` timing (the
        // whole suite's already-borderline `waitForExistence` windows started missing more
        // often once this call sat in `init()`'s synchronous path). Nothing observes
        // `NotificationActionDelegate.shared` before the next run loop tick regardless, so
        // deferring it costs nothing correctness-wise.
        Task { @MainActor in
            NotificationActionHandler.registerCategories()
            UNUserNotificationCenter.current().delegate = NotificationActionDelegate.shared
        }

        // Kue 2.0 Phase 11 — docs/26 "R.": real CloudKit never runs under `KueUITests`, same
        // seam every other Fake-under-UITests service uses. `nil` (no matching launch
        // argument) leaves `SyncCoordinator.shared`'s own default (system-backed) in place.
        if let fakeSyncCoordinator = SyncCoordinator.makeFromLaunchArguments() {
            SyncCoordinator.shared = fakeSyncCoordinator
        }

        if case .success(let container) = outcome {
            NotificationActionDelegate.shared.context = container.mainContext
            // Kue 2.0 Phase 4 — requirement 42's missing-event/conflict presentations need one
            // already-linked `KueEvent` present at launch. Triple-gated (isolated store AND
            // the fake-calendar argument AND one of these two specific sub-arguments) the same
            // way `ModelContainerFactory.resetUITestStore` is structurally gated — this seeding
            // call has no code path that can run against the real App Group store: it only
            // executes at all when `ModelContainerFactory.isUITestIsolatedStore` is already
            // true, which is itself only ever set by `KueUITests`.
            Self.seedCalendarFixtureIfNeeded(context: container.mainContext)
            Self.resetLockScreenSelectionIfNeeded()
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
                RootTabView()
                    // Real, on-device-only implementations — see docs/06-ai-layer.md "Parser
                    // runtime & credentials". Everywhere else in the app reads these only
                    // through the `NLParsing`/`AIAvailabilityChecking` environment seam
                    // (AIEnvironment.swift), so KueTests can swap in fixture-backed fakes and
                    // never reach this line.
                    .environment(\.nlParser, Self.makeNLParser())
                    .environment(\.aiAvailabilityChecker, Self.makeAIAvailabilityChecker())
                    // Kue 2.0 Phase 4 — real EventKit-backed access everywhere else in the
                    // app reads only through `\.calendarProvider` (CalendarEnvironment.swift),
                    // same DI seam as the AI environment above. Launched with
                    // `FakeCalendarProvider.uiTestLaunchArgument` (only ever set by
                    // `KueUITests`), a deterministic in-memory fixture is installed instead —
                    // requirement 43/44: never the real EventKit database in a UI test.
                    .environment(\.calendarProvider, Self.makeCalendarProvider())
                    // Kue 2.0 Phase 5 — real Vision-backed recognition everywhere else in the
                    // app reads only through `\.ocrTextRecognizer` (OCREnvironment.swift), same
                    // DI seam as Calendar above. `\.ocrUsesFixtureImageSource` swaps
                    // `OCRImportView`'s real `PhotosPicker` for a deterministic in-process
                    // fixture image under the same launch argument — requirement 45/48: never
                    // the owner's real Photos library in a UI test.
                    .environment(\.ocrTextRecognizer, Self.makeOCRTextRecognizer())
                    .environment(\.ocrUsesFixtureImageSource, ProcessInfo.processInfo.arguments.contains(FakeOCRTextRecognizer.uiTestLaunchArgument))
                    // Kue 2.0 Phase 6 — real AVAudioSession/AVAudioEngine/Speech-backed access
                    // everywhere else in the app reads only through these four environment
                    // values (VoiceEnvironment.swift). All four are launch-argument-gated
                    // together under `FakeVoiceSpeechRecognizer.uiTestLaunchArgument` —
                    // requirement 63: never the real microphone in a UI test.
                    .environment(\.voiceAuthorizationChecker, Self.makeVoiceAuthorizationChecker())
                    .environment(\.voiceAudioSessionManager, Self.makeVoiceAudioSessionManager())
                    .environment(\.voiceMicrophoneCapture, Self.makeVoiceMicrophoneCapture())
                    .environment(\.voiceSpeechRecognizer, Self.makeVoiceSpeechRecognizer())
                    // Kue 2.0 Phase 7 — same launch-argument-gated seam as Calendar/OCR/Voice
                    // above: haptics never fire under `XCUIApplication` automation.
                    .environment(\.kueHaptics, Self.makeHapticPlayer())
                    // Kue 2.0 Phase 9 — same seam again: real ActivityKit never runs under
                    // `KueUITests` (docs/23-live-activities-and-focus-mode.md "A./L.").
                    .environment(\.liveActivityManager, liveActivityManager)
                    // Kue 2.0 Phase 10 — same seam again: real Core Spotlight indexing never
                    // runs under `KueUITests` (docs/24-siri-shortcuts-spotlight-and-controls.md).
                    .environment(\.spotlightIndexer, spotlightIndexer)
                    .modelContainer(container)
            case .failure(let diagnostic):
                StoreOpenFailureView(diagnostic: diagnostic) {
                    openOutcome = ModelContainerFactory.makeDefaultOrDiagnostic()
                }
            }
        }
    }

    /// Kue 2.0 Phase 5 — Apple Intelligence isn't available in the iOS Simulator at all, so a
    /// `KueUITests` case that needs to drive OCR-recognized (or, Phase 6, voice-transcribed)
    /// text through to a real, deterministic parsed draft needs a fake here too — installed
    /// alongside either `FakeOCRTextRecognizer.uiTestLaunchArgument` or
    /// `FakeVoiceSpeechRecognizer.uiTestLaunchArgument`, since every OCR/Voice UI test that
    /// reaches "Continue" already passes one of those; see `FakeNLParser.swift`'s own header.
    @MainActor
    private static func makeNLParser() -> NLParsing {
        if #available(iOS 26.0, *), Self.usesFakeAIServices {
            return FakeNLParser()
        }
        return FoundationModelsParser()
    }

    @MainActor
    private static func makeAIAvailabilityChecker() -> AIAvailabilityChecking {
        if Self.usesFakeAIServices {
            return FakeAIAvailabilityChecker(stateToReturn: .available)
        }
        return SystemAIAvailabilityChecker()
    }

    private static var usesFakeAIServices: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(FakeOCRTextRecognizer.uiTestLaunchArgument)
            || arguments.contains(FakeVoiceSpeechRecognizer.uiTestLaunchArgument)
    }

    /// Kue 2.0 Phase 4 — same "launch-argument-gated fake" shape as
    /// `ModelContainerFactory.isUITestIsolatedStore`, one seam over. `MainActor`-isolated (both
    /// conformers require it), so this is called from `body` rather than stored as a stashed
    /// `let` at `init()` time — SwiftUI `App.init()` isn't guaranteed `@MainActor`.
    @MainActor
    private static func makeCalendarProvider() -> CalendarProviding {
        FakeCalendarProvider.makeFromLaunchArguments() ?? SystemCalendarProvider()
    }

    /// Kue 2.0 Phase 5 — same "launch-argument-gated fake" shape as `makeCalendarProvider()`.
    @MainActor
    private static func makeOCRTextRecognizer() -> OCRTextRecognizing {
        FakeOCRTextRecognizer.makeFromLaunchArguments() ?? SystemOCRTextRecognizer()
    }

    /// Kue 2.0 Phase 6 — all four Voice services are gated together by the *same* launch
    /// argument (`FakeVoiceSpeechRecognizer.uiTestLaunchArgument`), since a `KueUITests` case
    /// exercising voice input needs every one of them faked at once — a real audio session or
    /// microphone tap with a fake recognizer behind it would still touch real hardware.
    @MainActor
    private static func makeVoiceAuthorizationChecker() -> VoiceAuthorizationChecking {
        guard ProcessInfo.processInfo.arguments.contains(FakeVoiceSpeechRecognizer.uiTestLaunchArgument) else {
            return SystemVoiceAuthorizationChecker()
        }
        let denied = ProcessInfo.processInfo.arguments.contains(FakeVoiceAuthorizationChecker.uiTestMicrophoneDeniedArgument)
        let restricted = ProcessInfo.processInfo.arguments.contains(FakeVoiceAuthorizationChecker.uiTestSpeechRestrictedArgument)
        let fake = FakeVoiceAuthorizationChecker()
        fake.microphoneStateToReturn = denied ? .denied : .authorized
        fake.speechStateToReturn = restricted ? .restricted : .authorized
        return fake
    }

    @MainActor
    private static func makeVoiceAudioSessionManager() -> VoiceAudioSessionManaging {
        guard ProcessInfo.processInfo.arguments.contains(FakeVoiceSpeechRecognizer.uiTestLaunchArgument) else {
            return SystemVoiceAudioSessionManager()
        }
        let fake = FakeVoiceAudioSessionManager()
        if ProcessInfo.processInfo.arguments.contains(FakeVoiceAudioSessionManager.uiTestSimulateInterruptionArgument) {
            fake.simulateInterruptionAfterNanoseconds = 1_500_000_000
        }
        return fake
    }

    @MainActor
    private static func makeVoiceMicrophoneCapture() -> VoiceMicrophoneCapturing {
        ProcessInfo.processInfo.arguments.contains(FakeVoiceSpeechRecognizer.uiTestLaunchArgument)
            ? FakeVoiceMicrophoneCapture()
            : SystemVoiceMicrophoneCapture()
    }

    @MainActor
    private static func makeVoiceSpeechRecognizer() -> VoiceSpeechRecognizing {
        FakeVoiceSpeechRecognizer.makeFromLaunchArguments() ?? SystemVoiceSpeechRecognizer()
    }

    /// Kue 2.0 Phase 9 — same "launch-argument-gated fake" shape as `makeCalendarProvider()`.
    @MainActor
    private static func makeLiveActivityManager() -> LiveActivityManaging {
        FakeLiveActivityManager.makeFromLaunchArguments() ?? SystemLiveActivityManager.shared
    }

    /// Kue 2.0 Phase 10 — same shape again.
    @MainActor
    private static func makeSpotlightIndexer() -> SpotlightIndexing {
        FakeSpotlightIndexer.makeFromLaunchArguments() ?? SystemSpotlightIndexer.shared
    }

    /// Kue 2.0 Phase 7 — UI tests already launch with one of the fake-service arguments above
    /// whenever they exercise a haptic-triggering action; reusing `usesFakeAIServices`'s
    /// underlying check would be wrong (haptics fire on far more screens than AI-gated ones),
    /// so this checks for *any* `KueUITests` launch argument via the same isolated-store flag
    /// every other seam in this file keys off.
    @MainActor
    private static func makeHapticPlayer() -> KueHapticPlaying {
        ModelContainerFactory.isUITestIsolatedStore ? FakeHapticPlayer() : SystemHapticPlayer.shared
    }

    /// Kue 2.0 Phase 4 — see the call site's own comment above for the full gating argument.
    /// Post-Phase-12 fix — `LockScreenEventSelection` is real App Group `UserDefaults` state,
    /// same as `SyncPreference`/`ReminderPreference`/etc.: `-uiTestIsolatedStore` wipes the
    /// SwiftData store clean at every launch (`ModelContainerFactory`'s own header), but never
    /// touched App-Group-`UserDefaults`-backed preferences, so a selection made by one
    /// `KueUITests` case previously ran on this simulator could otherwise leak into a later,
    /// unrelated test's launch (confirmed empirically — a stale selection from an earlier test
    /// run showed as "no longer available" in a test that never selected anything itself).
    /// Only this one preference needs clearing here: the others aren't yet read by anything a
    /// UI test asserts against in a way that would be corrupted by residual state.
    private static func resetLockScreenSelectionIfNeeded() {
        guard ModelContainerFactory.isUITestIsolatedStore else { return }
        LockScreenEventSelection.clear()
    }

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
