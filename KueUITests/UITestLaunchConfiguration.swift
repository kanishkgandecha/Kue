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
    /// Leaves first-run onboarding visible; isolated UI tests suppress it by default.
    static let showOnboardingArgument = "-uiTestShowOnboarding"

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

    /// Kue 2.0 Phase 9 — must match `FakeLiveActivityManager.uiTestLaunchArgument` exactly.
    /// `KueApp` installs a `FakeLiveActivityManager` in place of `SystemLiveActivityManager`
    /// when present — real ActivityKit never runs under `KueUITests`.
    static let fakeLiveActivityArgument = "-uiTestFakeLiveActivity"

    /// Kue 2.0 Phase 10 — must match `FakeSpotlightIndexer.uiTestLaunchArgument` exactly.
    /// `KueApp` installs a `FakeSpotlightIndexer` in place of `SystemSpotlightIndexer` when
    /// present — the real on-device Core Spotlight index never runs under `KueUITests`.
    static let fakeSpotlightArgument = "-uiTestFakeSpotlight"

    /// Kue 2.0 Phase 11 — must match `SyncCoordinator.uiTestLaunchArgument` exactly. `KueApp`
    /// installs a fully fake-backed `SyncCoordinator` (in-memory transport/account/state
    /// store, sync pre-enabled) in place of the real `CKSyncEngine`-backed one when present —
    /// real CloudKit never runs under `KueUITests`.
    static let fakeSyncArgument = "-uiTestFakeSync"

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

// Kue 2.0 Phase 7 — Event Detail gained a new header section (status badge + preparation
// progress) above "Info"/"Actions", pushing every row below it further down. A `Form`'s rows
// aren't in the accessibility tree until actually scrolled into view, so any Actions-section
// button below that header (Delete, Add/Update Calendar, Duplicate) isn't reliably materialized
// or hittable on first render — this used to live as a private one-file helper in
// EventManagementUITests before more than one file needed it.
extension XCUIElement {
    /// Swipes `app` up, a bounded number of times, until `self` actually exists and is
    /// hittable — doesn't assume whether SwiftUI's `Form` renders as a `UITableView` or
    /// `UICollectionView` under the hood (that's changed across iOS versions), and never
    /// assumes a fixed scroll distance.
    func scrollUpUntilHittable(in app: XCUIApplication, maxSwipes: Int = 6) {
        var attempts = 0
        while !(exists && isHittable) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }
}

// Kue 2.0 Phase 7 — the bottom navigation bar replaced Home's old toolbar (Add/Settings/
// Templates/More-Ways-to-Add menu/Filter & Sort). Every test file's old direct
// `app.buttons["addEventButton"/"settingsButton"/...].tap()` call routed through exactly this
// shape, so these are the one place that shape needed to change — every UI test below now goes
// through one of these instead of re-deriving the new navigation path itself.
extension XCUIApplication {
    /// Selects one of the five bottom-navigation destinations by its `tab-*` identifier
    /// (`RootTabView.swift`).
    func selectTab(_ identifier: String) {
        let tab = buttons[identifier]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Expected tab bar button \(identifier) to exist.")
        tab.tap()
    }

    /// Opens the Add tab and starts "Create Manually" — equivalent of the old single-tap
    /// `addEventButton`, which opened the identical `EventFormView` sheet directly.
    func openManualAddForm() {
        selectTab("tab-add")
        let manual = buttons["addMethodManual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.tap()
    }

    /// Opens the Add tab and taps one of its rows directly — equivalent of the old
    /// `moreAddOptionsButton` menu, whose items (`importFromCalendarButton`/
    /// `scanScreenshotButton`/`voiceInputButton`) now live on `AddHubView` with no menu step.
    func openAddMethod(_ identifier: String) {
        selectTab("tab-add")
        let row = buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    /// A freshly created event's `startDate` defaults to "now," so it can reach a terminal
    /// widget/notification phase within seconds of saving (before this call even runs). Kue
    /// 2.0 Phase 10.1 (docs/25): that phase is `awaitingOutcome`, which Home shows in its
    /// always-visible Needs Attention section — no expansion needed, so this now typically
    /// short-circuits at the guard below. Kept as a general fallback for the genuinely
    /// `.completed`/explicit-mark-complete case, which still lands inside Home's
    /// collapsed-by-default Completed section instead of a date section, invisible to a plain
    /// `app.staticTexts[title]` lookup. Only expands the Completed disclosure when `title`
    /// isn't already on-screen (an ordinary date-sectioned or Needs-Attention event needs no
    /// help, and a second call within the same test — the disclosure is already expanded —
    /// never accidentally re-collapses it), matching how a user would open the section to
    /// check.
    func revealHomeEventIfInsideCollapsedCompletedSection(titled title: String) {
        guard !staticTexts[title].waitForExistence(timeout: 2) else { return }
        // A `DisclosureGroup`'s own accessibility identifier resolves to an ambiguous element
        // whose reported automation type XCUITest itself flags as mismatched ("computed Other
        // from legacy attributes vs StaticText from modern attribute") — tapping *that* element
        // (matched via `.any`) synthesizes a tap at the wrong coordinates entirely (observed
        // landing on the Templates tab instead). The disclosure's own label text — "Completed
        // (N)" — renders as a plain, correctly-positioned `StaticText`; tapping that instead
        // reliably toggles the same disclosure.
        let header = staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Completed ('")).firstMatch
        if header.waitForExistence(timeout: 2) {
            header.tap()
        }
    }
}
