//
//  UITestLaunchConfiguration.swift
//  KueUITests
//
//  Kue 2.0 Phase 3 post-implementation cleanup — UI-test store isolation. Every `KueUITests`
//  case that drives the real app passes `isolatedStoreArgument` via
//  `XCUIApplication.launchArguments` before `app.launch()`; `ModelContainerFactory` (Shared/,
//  compiled into the app target — `KueUITests` itself has no access to it, since it drives
//  the app externally rather than importing its module) recognizes the *same literal string*
//  and, only when present, opens a store outside the App Group container that's wiped clean
//  at the start of every launch. This one shared constant is what keeps the two sides of that
//  contract from silently drifting apart — see `ModelContainerFactory.uiTestLaunchArgument`'s
//  own header for the full rationale and the safety argument for why this can never reach
//  production data.
//

import XCTest

enum UITestLaunchConfiguration {
    /// Must match `ModelContainerFactory.uiTestLaunchArgument` exactly.
    static let isolatedStoreArgument = "-uiTestIsolatedStore"

    /// Kue 2.0 Phase 4 — must match `FakeCalendarProvider.uiTestLaunchArgument` exactly.
    /// `KueApp` installs a `FakeCalendarProvider` in place of `SystemCalendarProvider` when
    /// present — the same "shared literal, same rationale" as `isolatedStoreArgument` above, so
    /// Calendar UI tests never touch the real EventKit database (requirement 43/44).
    static let fakeCalendarArgument = "-uiTestFakeCalendar"
    /// Must match `FakeCalendarProvider.uiTestDeniedArgument`/`uiTestRestrictedArgument`/
    /// `uiTestNotDeterminedArgument` exactly — selects which authorization state the fake
    /// starts in (default, with just `fakeCalendarArgument` alone, is full access with fixture
    /// events).
    static let fakeCalendarDeniedArgument = "-uiTestFakeCalendarDenied"
    static let fakeCalendarRestrictedArgument = "-uiTestFakeCalendarRestricted"
    static let fakeCalendarNotDeterminedArgument = "-uiTestFakeCalendarNotDetermined"
    /// Must match `FakeCalendarProvider.uiTestPreLinkedMissingArgument`/
    /// `uiTestPreLinkedConflictArgument` exactly — `KueApp` seeds one already-linked `KueEvent`
    /// into the isolated store at launch for requirement 42's missing-event/conflict tests.
    static let fakeCalendarPreLinkedMissingArgument = "-uiTestFakeCalendarPreLinkedMissing"
    static let fakeCalendarPreLinkedConflictArgument = "-uiTestFakeCalendarPreLinkedConflict"

    /// Kue 2.0 Phase 5 — must match `FakeOCRTextRecognizer.uiTestLaunchArgument` exactly.
    /// `KueApp` installs a `FakeOCRTextRecognizer` in place of `SystemOCRTextRecognizer` when
    /// present, and `OCRImportView` swaps its real `PhotosPicker` for a deterministic
    /// in-process fixture image — requirement 45/48: never the owner's real Photos library or
    /// uncontrolled Vision recognition in a UI test.
    static let fakeOCRArgument = "-uiTestFakeOCR"
    /// Must match `FakeOCRTextRecognizer`'s equivalents exactly — selects which recognition
    /// outcome the fake returns (default, with just `fakeOCRArgument` alone, is a clear,
    /// high-confidence fixture result).
    static let fakeOCRLowConfidenceArgument = "-uiTestFakeOCRLowConfidence"
    static let fakeOCRNoTextArgument = "-uiTestFakeOCRNoText"
    static let fakeOCRFailureArgument = "-uiTestFakeOCRFailure"
    static let fakeOCRUnavailableArgument = "-uiTestFakeOCRUnavailable"

    /// Kue 2.0 Phase 6 — must match `FakeVoiceSpeechRecognizer.uiTestLaunchArgument` exactly.
    /// `KueApp` installs the fake authorization/audio-session/microphone-capture/speech-
    /// recognizer quartet together when present — requirement 63: never the simulator's or
    /// owner's real microphone in a UI test.
    static let fakeVoiceArgument = "-uiTestFakeVoice"
    /// Must match `FakeVoiceSpeechRecognizer`'s equivalents exactly.
    static let fakeVoiceOnDeviceUnsupportedArgument = "-uiTestFakeVoiceOnDeviceUnsupported"
    static let fakeVoiceUnavailableArgument = "-uiTestFakeVoiceUnavailable"
    static let fakeVoiceNoSpeechArgument = "-uiTestFakeVoiceNoSpeech"
    static let fakeVoiceFailureArgument = "-uiTestFakeVoiceFailure"
    static let fakeVoiceLowConfidenceArgument = "-uiTestFakeVoiceLowConfidence"
    /// Must match `FakeVoiceAuthorizationChecker`'s equivalents exactly.
    static let fakeVoiceMicrophoneDeniedArgument = "-uiTestFakeVoiceMicrophoneDenied"
    static let fakeVoiceSpeechRestrictedArgument = "-uiTestFakeVoiceSpeechRestricted"
    /// Must match `FakeVoiceAudioSessionManager.uiTestSimulateInterruptionArgument` exactly.
    static let fakeVoiceInterruptionArgument = "-uiTestFakeVoiceInterruption"

    /// The simulator's interface orientation is a *device*-level property, not scoped to one
    /// app process — it doesn't reset just because a test relaunches the app. A stray rotation
    /// left over from an earlier test (or an earlier run against the same booted simulator)
    /// otherwise carries into every later test's layout math, which is exactly the kind of
    /// hidden execution-order dependency this cleanup is meant to remove. Call once per test
    /// class's `setUpWithError`, before `app.launch()`, so every test always starts portrait
    /// regardless of what any earlier test left the simulator in.
    static func resetDeviceOrientation() {
        XCUIDevice.shared.orientation = .portrait
    }
}
