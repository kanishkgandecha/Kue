//
//  LiveActivityFocusUITests.swift
//  KueUITests
//
//  See docs/23-live-activities-and-focus-mode.md "L." — the app-owned Focus surfaces (Event
//  Detail's Focus section, Settings' Focus management surface), driven entirely through
//  `FakeLiveActivityManager` (`UITestLaunchConfiguration.fakeLiveActivityArgument` — real
//  ActivityKit never runs here). Per the phase's own explicit instruction, this deliberately
//  does NOT attempt SpringBoard/real-Lock-Screen/Dynamic-Island automation — the Lock Screen
//  and Dynamic Island rendering itself is a manual-verification item (docs/23 "M."), and a
//  `kue://` deep link opening the app from outside its own process has no reliable public
//  XCUITest API in this SDK, so that path is covered at the unit level
//  (`LiveActivityReconcilerTests`) instead. What's automatable here — starting, showing active
//  controls, stopping, the replacement confirmation (both declining and accepting), and the
//  Settings privacy toggles/management surface — is exactly the app's own UI, covered below.
//

import XCTest

final class LiveActivityFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeLiveActivityArgument]
        app.launch()
    }

    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Unlike `EventManagementUITests`' own `createEvent`, this always picks "Exam" (120-minute
    /// default duration) — the manual-add default event type (Generic) has a *zero*-minute
    /// default duration, so a "now"-started default event is already `.completed` by the time
    /// this helper returns, making it ineligible for a Live Activity
    /// (`WidgetContentService.isEligibleForDedicatedSelection`) before the test ever gets to
    /// tap "Start."
    private func createEvent(title: String) {
        app.openManualAddForm()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["eventTypePicker"].tap()
        if app.buttons["Exam"].waitForExistence(timeout: 2) {
            app.buttons["Exam"].tap()
        }
        app.buttons["saveEventButton"].tap()
        app.selectTab("tab-home")
        app.revealHomeEventIfInsideCollapsedCompletedSection(titled: title)
    }

    private func openEventDetail(titled title: String) {
        app.staticTexts[title].tap()
    }

    // MARK: - Start / active controls / stop

    func testStartingALiveActivityShowsActiveControlsAndAllowsStopping() {
        let title = uniqueTitle("Focus Start")
        createEvent(title: title)
        openEventDetail(titled: title)

        let startButton = app.buttons["startLiveActivityButton"]
        startButton.scrollUpUntilHittable(in: app)
        XCTAssertTrue(startButton.exists)
        startButton.tap()

        let activeLabel = app.staticTexts["liveActivityActiveLabel"]
        XCTAssertTrue(activeLabel.waitForExistence(timeout: 5))
        let stopButton = app.buttons["stopLiveActivityButton"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))

        stopButton.tap()
        let restartButton = app.buttons["startLiveActivityButton"]
        XCTAssertTrue(restartButton.waitForExistence(timeout: 5))
    }

    // MARK: - Replacement: confirmation required, decline vs. accept

    func testStartingASecondEventPromptsReplacementConfirmation() {
        let titleA = uniqueTitle("Focus A")
        let titleB = uniqueTitle("Focus B")
        createEvent(title: titleA)
        openEventDetail(titled: titleA)
        let startA = app.buttons["startLiveActivityButton"]
        startA.scrollUpUntilHittable(in: app)
        startA.tap()
        XCTAssertTrue(app.staticTexts["liveActivityActiveLabel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to Home

        createEvent(title: titleB)
        openEventDetail(titled: titleB)
        let startB = app.buttons["startLiveActivityButton"]
        startB.scrollUpUntilHittable(in: app)
        startB.tap()

        XCTAssertTrue(app.buttons["confirmReplaceLiveActivityButton"].waitForExistence(timeout: 5))
    }

    func testDecliningReplacementLeavesTheOriginalEventsActivityRunning() {
        let titleA = uniqueTitle("Focus Decline A")
        let titleB = uniqueTitle("Focus Decline B")
        createEvent(title: titleA)
        openEventDetail(titled: titleA)
        let startA = app.buttons["startLiveActivityButton"]
        startA.scrollUpUntilHittable(in: app)
        startA.tap()
        XCTAssertTrue(app.staticTexts["liveActivityActiveLabel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        createEvent(title: titleB)
        openEventDetail(titled: titleB)
        let startB = app.buttons["startLiveActivityButton"]
        startB.scrollUpUntilHittable(in: app)
        startB.tap()
        let confirmButton = app.buttons["confirmReplaceLiveActivityButton"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        // This SDK renders `.confirmationDialog` as a centered popover (not a bottom action
        // sheet) — there's no separate "Cancel" row at all; tapping the dimmed surrounding
        // region is the system's own decline gesture, backed by `PopoverDismissRegion`.
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertFalse(confirmButton.exists)

        // Event B never actually started — its own Start button is still offered.
        XCTAssertTrue(app.buttons["startLiveActivityButton"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Event A's activity is still the one running.
        openEventDetail(titled: titleA)
        let activeLabel = app.staticTexts["liveActivityActiveLabel"]
        activeLabel.scrollUpUntilHittable(in: app)
        XCTAssertTrue(activeLabel.exists)
    }

    func testAcceptingReplacementSwitchesFocusToTheNewEvent() {
        let titleA = uniqueTitle("Focus Accept A")
        let titleB = uniqueTitle("Focus Accept B")
        createEvent(title: titleA)
        openEventDetail(titled: titleA)
        let startA = app.buttons["startLiveActivityButton"]
        startA.scrollUpUntilHittable(in: app)
        startA.tap()
        XCTAssertTrue(app.staticTexts["liveActivityActiveLabel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        createEvent(title: titleB)
        openEventDetail(titled: titleB)
        let startB = app.buttons["startLiveActivityButton"]
        startB.scrollUpUntilHittable(in: app)
        startB.tap()
        let confirmButton = app.buttons["confirmReplaceLiveActivityButton"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertTrue(app.staticTexts["liveActivityActiveLabel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Event A must have been ended, not left running alongside B (one-event invariant).
        openEventDetail(titled: titleA)
        let restartButton = app.buttons["startLiveActivityButton"]
        restartButton.scrollUpUntilHittable(in: app)
        XCTAssertTrue(restartButton.exists)
    }

    // MARK: - Settings: privacy toggles + focus management surface

    func testSettingsShowsNoFocusedActivityWhenNoneIsRunning() {
        app.selectTab("tab-settings")
        let noneLabel = app.staticTexts["noFocusedLiveActivityLabel"]
        noneLabel.scrollUpUntilHittable(in: app)
        XCTAssertTrue(noneLabel.exists)
    }

    func testPrivacyTogglesAreReachableAndToggleWithoutCrashing() {
        app.selectTab("tab-settings")
        let titleToggle = app.switches["liveActivityShowTitleToggle"]
        titleToggle.scrollUpUntilHittable(in: app)
        XCTAssertTrue(titleToggle.exists)
        titleToggle.tap()

        let nextTaskToggle = app.switches["liveActivityShowNextTaskToggle"]
        XCTAssertTrue(nextTaskToggle.exists)
        nextTaskToggle.tap()
    }

    func testSettingsShowsAndCanStopTheFocusedEventsActivity() {
        let title = uniqueTitle("Focus Settings Stop")
        createEvent(title: title)
        openEventDetail(titled: title)
        let startButton = app.buttons["startLiveActivityButton"]
        startButton.scrollUpUntilHittable(in: app)
        startButton.tap()
        XCTAssertTrue(app.staticTexts["liveActivityActiveLabel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.selectTab("tab-settings")
        let openLink = app.buttons["openFocusedLiveActivityEventLink"]
        openLink.scrollUpUntilHittable(in: app)
        XCTAssertTrue(openLink.waitForExistence(timeout: 5))

        let stopButton = app.buttons["settingsStopLiveActivityButton"]
        stopButton.scrollUpUntilHittable(in: app)
        stopButton.tap()

        let noneLabel = app.staticTexts["noFocusedLiveActivityLabel"]
        noneLabel.scrollUpUntilHittable(in: app)
        XCTAssertTrue(noneLabel.waitForExistence(timeout: 5))
    }
}
