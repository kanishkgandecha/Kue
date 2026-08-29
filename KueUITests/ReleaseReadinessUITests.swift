//
//  ReleaseReadinessUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 12 — focused first-run and Settings replay coverage. System permission
//  dialogs and the Files picker remain outside app-owned UI automation.
//

import XCTest

final class ReleaseReadinessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [
            UITestLaunchConfiguration.isolatedStoreArgument,
            UITestLaunchConfiguration.showOnboardingArgument
        ]
        app.launch()
    }

    func testOnboardingIsSkippableAndNeverShowsAPermissionPrompt() {
        XCTAssertTrue(app.navigationBars["Welcome to Kue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboardingContinueButton"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        app.buttons["onboardingSkipButton"].tap()
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    }

    func testOnboardingExplainsPrivacyAndBackup() {
        XCTAssertTrue(app.navigationBars["Welcome to Kue"].waitForExistence(timeout: 5))
        for _ in 0..<3 {
            app.buttons["onboardingContinueButton"].tap()
        }
        XCTAssertTrue(app.staticTexts["Keep a backup you control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboardingRestoreBackupButton"].exists)
        XCTAssertTrue(app.buttons["onboardingContinueButton"].exists)
    }
}
