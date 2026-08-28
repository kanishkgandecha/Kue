//
//  CloudSyncUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "S." UI tests for the Settings iCloud
//  Sync section, entirely against `SyncCoordinator.makeFromLaunchArguments()`'s fully
//  fake-backed instance (in-memory transport/account/state store) — no real CloudKit, no
//  real account, ever.
//

import XCTest

final class CloudSyncUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeSyncArgument]
        app.launch()
        app.selectTab("tab-settings")
    }

    /// The iCloud Sync section sits well below Notifications/AI/Calendar/Siri/Live Activity
    /// in Settings' `Form` — not materialized in the accessibility tree until scrolled into
    /// view, same class of issue `scrollUpUntilHittable`'s own doc comment already covers for
    /// Event Detail's Actions section. Scroll *before* asserting existence, not after.
    private func toggle() -> XCUIElement {
        let element = app.switches["iCloudSyncToggle"]
        element.scrollUpUntilHittable(in: app)
        // `RecurringEventsUITests`'s own `scrollUntilExists` establishes the same fix for the
        // same reason: a `Form`'s scroll/insert animation can leave a just-revealed row's real
        // hit-test frame lagging behind what `isHittable` already reported true a moment
        // earlier — a short settle avoids racing that before the very next `.tap()`.
        Thread.sleep(forTimeInterval: 0.3)
        return element
    }

    /// Root cause found via `app.debugDescription`: `app.switches["iCloudSyncToggle"]`
    /// resolves to the *row's own* accessibility element (370pt wide, the identifier is on
    /// the `Toggle` itself, which spans the whole row) — but the real interactive `UISwitch`
    /// glyph nested inside it sits at the row's right edge (frame `{309, ..., 63, 28}` within
    /// a 370pt-wide row), not centered. A dead-center tap (plain `.tap()`, or a coordinate at
    /// `dx: 0.5`) lands on the row's label/background area, which does not toggle it — only
    /// the glyph itself does. `dx: 0.9` lands inside that glyph.
    private func tapToggle() {
        app.switches["iCloudSyncToggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    func testICloudSyncToggleAndStatusAreVisible() {
        let toggle = toggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // The fake is pre-enabled by `SyncCoordinator.makeFromLaunchArguments()`.
        XCTAssertEqual(toggle.value as? String, "1")
        let statusLabel = app.descendants(matching: .any)["syncStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))
    }

    func testSyncNowButtonIsPresentAndTappable() {
        _ = toggle() // scrolls the section into view first
        let syncNowButton = app.buttons["syncNowButton"]
        syncNowButton.scrollUpUntilHittable(in: app)
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))
        syncNowButton.tap()
        // No crash, no hang — the fake transport resolves immediately.
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))
    }

    func testDisablingSyncTurnsToggleOffAndHidesDetailRows() {
        let toggle = toggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["syncNowButton"].waitForExistence(timeout: 5))
        tapToggle()
        // Detail rows (status/Sync Now) are gated behind `isSyncEnabled` — docs/26 "K.":
        // disabling stops transfers but the toggle itself remains the one source of truth.
        XCTAssertFalse(app.buttons["syncNowButton"].waitForExistence(timeout: 3))
    }

    func testReEnablingSyncAfterDisablingRestoresDetailRows() {
        let toggle = toggle()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["syncNowButton"].waitForExistence(timeout: 5))
        tapToggle() // off
        XCTAssertFalse(app.buttons["syncNowButton"].waitForExistence(timeout: 3))
        tapToggle() // back on
        let syncNowButton = app.buttons["syncNowButton"]
        syncNowButton.scrollUpUntilHittable(in: app)
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))
    }

    func testICloudSyncSectionHasAPrivacyExplanationFooter() {
        _ = toggle() // scrolls the section into view first
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'iCloud'")).firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
    }
}
