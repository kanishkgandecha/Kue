//
//  CloudSyncUITests.swift
//  KueUITests
//
//  Kue 3.0 Phase 5 — docs/33 "Sync status and controls." UI tests for Settings' "Sync"
//  section, entirely against `SyncCoordinator.makeFromLaunchArguments()`'s fake-backed
//  transport and `FakeAccountProvider`'s fixture account — no real Supabase project, no real
//  network, ever. Renamed in purpose (not filename — kept for git-history continuity) from
//  Kue 2.0 Phase 11's CloudKit-era file: the sync UI now lives behind a signed-in account
//  (Phase 4) and a completed first-sync decision (Phase 5), so every test here signs in with
//  the fixture account first, exactly like `AccountUITests.swift`'s own `signInWithFixture()`.
//

import XCTest

final class CloudSyncUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [
            UITestLaunchConfiguration.isolatedStoreArgument,
            UITestLaunchConfiguration.fakeSyncArgument,
            UITestLaunchConfiguration.fakeAccountArgument,
        ]
        app.launch()
        signInWithFixtureAccount()
    }

    /// Mirrors `AccountUITests.signInWithFixture()` — the sync section only ever shows real
    /// controls once an account is signed in (Phase 4/5's own "no sync while signed out"
    /// requirement), so every test here reaches that state first.
    private func signInWithFixtureAccount() {
        app.selectTab("tab-settings")
        let accountLink = app.buttons["accountLink"]
        accountLink.scrollUpUntilHittable(in: app)
        XCTAssertTrue(accountLink.waitForExistence(timeout: 5))
        accountLink.tap()
        app.buttons["signInButton"].tap()
        let emailField = app.textFields["signInEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText("fixture@kue.test")
        let passwordField = app.secureTextFields["signInPasswordField"]
        passwordField.tap()
        passwordField.typeText("fixture-password-123")
        app.buttons["submitSignInButton"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixtureuser'")).firstMatch.waitForExistence(timeout: 5))
        // Back to the Settings root. Found via `app.debugDescription` that a plain tap on the
        // navigation bar's own back button (by either its label "Settings" or its real fixed
        // identifier "BackButton") never actually popped the stack here — re-selecting the
        // already-active "tab-settings" tab is what `RootTabView` itself already uses to reset
        // a tab's own navigation stack to its root (the same pattern other UI tests in this
        // suite rely on for exactly this "get back to a known screen" need), sidestepping
        // whatever this specific back-button tap's own unexplained failure is.
        app.selectTab("tab-home")
        app.selectTab("tab-settings")
        // `accountLink` only exists on the Settings root, never on AccountProfileView. Not
        // immediately on screen without scrolling (same `Form`-virtualization behavior
        // `AccountUITests.openAccountScreen()` already scrolls for).
        accountLink.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(accountLink.waitForExistence(timeout: 5))
    }

    /// The "Sync" section sits well below Notifications/AI/Calendar/Siri/Live Activity in
    /// Settings' `Form` — not materialized in the accessibility tree until scrolled into view.
    private func syncToggle() -> XCUIElement {
        let element = app.switches["syncToggle"]
        element.scrollUpUntilHittable(in: app, maxSwipes: 20)
        Thread.sleep(forTimeInterval: 0.3) // let the scroll/insert animation settle before tapping
        return element
    }

    /// Same root cause `scrollUpUntilHittable`'s own header and this file's Kue 2.0 Phase 11
    /// history already found: a dead-center tap can land on the row's label, not the switch
    /// glyph at its trailing edge.
    private func tapToggle() {
        app.switches["syncToggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    /// The very first toggle tap under a fresh fixture account reaches the first-sync decision
    /// sheet, not the toggle turning straight on — this drives past it with "Turn On Sync"
    /// (the "nothing anywhere yet" path, since the fake transport/local store both start empty).
    private func completeFirstSyncDecisionIfPresented() {
        let primary = app.buttons["firstSyncPrimaryButton"]
        if primary.waitForExistence(timeout: 3) {
            primary.tap()
        }
    }

    func testSyncToggleAndStatusAreVisibleAfterTheFirstSyncDecision() {
        let setUpButton = app.buttons["setUpSyncButton"]
        setUpButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(setUpButton.waitForExistence(timeout: 5))
        setUpButton.tap()
        completeFirstSyncDecisionIfPresented()

        let toggle = syncToggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        let statusLabel = app.descendants(matching: .any)["syncStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
    }

    func testSyncNowButtonIsPresentAndTappable() {
        let setUp = app.buttons["setUpSyncButton"]
        setUp.scrollUpUntilHittable(in: app, maxSwipes: 20)
        setUp.tap()
        completeFirstSyncDecisionIfPresented()
        _ = syncToggle()

        let syncNowButton = app.buttons["syncNowButton"]
        syncNowButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))
        syncNowButton.tap()
        // No crash, no hang — the fake transport resolves immediately.
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))
    }

    func testDisablingSyncRequiresConfirmationAndThenHidesDetailRows() {
        app.buttons["setUpSyncButton"].scrollUpUntilHittable(in: app, maxSwipes: 20)
        app.buttons["setUpSyncButton"].tap()
        completeFirstSyncDecisionIfPresented()
        let toggle = syncToggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["syncNowButton"].waitForExistence(timeout: 5))

        tapToggle()
        // Requirement P: "no destructive reset button without a separate confirmation" — the
        // toggle itself must not have flipped off yet; the confirmation dialog appears first.
        // `confirmationDialog`'s action-sheet presentation duplicates its buttons in the
        // accessibility tree (an onscreen copy and an offscreen one mid-transition) — same
        // shape already resolved elsewhere in this codebase (`AccountUITests`) with `.firstMatch`.
        let confirmButton = app.buttons["confirmDisableSyncButton"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertFalse(app.buttons["syncNowButton"].waitForExistence(timeout: 3))
    }

    /// Phase 5 correction (requirement 8): every other test in this file drives past the
    /// first-sync decision with its *primary* button — this is the one dedicated test of the
    /// "Not Now" path (`AccountFirstSyncDecisionView`'s toolbar action), which defers the
    /// decision rather than making it, and must leave sync off with no sync controls shown.
    func testDecliningTheFirstSyncDecisionWithNotNowLeavesSyncOff() {
        let setUpButton = app.buttons["setUpSyncButton"]
        setUpButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        setUpButton.tap()
        let notNow = app.buttons["firstSyncNotNowButton"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        // Never a half-on state — no sync toggle/controls appear until the decision is actually
        // made (requirement J: "never silently replace... never silently upload").
        XCTAssertFalse(app.switches["syncToggle"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["syncNowButton"].waitForExistence(timeout: 2))
    }

    func testSyncSectionHasAPrivacyExplanationFooter() {
        app.buttons["setUpSyncButton"].scrollUpUntilHittable(in: app, maxSwipes: 20)
        app.buttons["setUpSyncButton"].tap()
        completeFirstSyncDecisionIfPresented()
        _ = syncToggle()
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Row Level Security'")).firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
    }
}
