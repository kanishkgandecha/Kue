//
//  InsightsUITests.swift
//  KueUITests
//
//  Kue 3.0 Phase 6 — docs/34 "iPhone experience." Focused UI coverage for the new Insights
//  destination — entirely against `FakeAccountProvider`/`FakeStatisticsTransport`-backed
//  coordinators, no real network, no real account, ever.
//

import XCTest

final class InsightsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [
            UITestLaunchConfiguration.isolatedStoreArgument,
            UITestLaunchConfiguration.fakeAccountArgument,
            UITestLaunchConfiguration.fakeStatisticsArgument,
        ]
        app.launch()
    }

    private func openInsights() {
        app.selectTab("tab-settings")
        let link = app.buttons["insightsLink"]
        link.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.staticTexts["Your Activity"].waitForExistence(timeout: 5))
    }

    /// Mirrors `AccountUITests.signInWithFixture()`/`CloudSyncUITests.signInWithFixtureAccount()`.
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
        app.selectTab("tab-home")
    }

    // MARK: - Local statistics, reachable while signed out (requirement A)

    func testInsightsIsReachableAndShowsTheEmptyStateWhileSignedOut() {
        openInsights()
        XCTAssertTrue(app.staticTexts["No Activity Yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local Only — this device"].waitForExistence(timeout: 3))
    }

    // MARK: - Consent flow

    func testEnablingCloudStatisticsWhileSignedOutGuidesToSignIn() {
        openInsights()
        let toggle = app.switches["cloudStatisticsToggle"]
        toggle.scrollUpUntilHittable(in: app, maxSwipes: 20)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // Never silently flips on while signed out — a sign-in guide sheet appears instead.
        XCTAssertTrue(app.navigationBars.buttons["signInButton"].waitForExistence(timeout: 8) || app.buttons["signInButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testEnablingCloudStatisticsWhileSignedInShowsConsentThenEnables() {
        signInWithFixtureAccount()
        openInsights()
        let toggle = app.switches["cloudStatisticsToggle"]
        toggle.scrollUpUntilHittable(in: app, maxSwipes: 20)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        let confirm = app.buttons["confirmEnableCloudStatisticsButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()

        XCTAssertEqual(toggle.value as? String, "1")
        let deleteButton = app.buttons["deleteCloudStatisticsButton"]
        deleteButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
    }

    func testDeletingCloudStatisticsRequiresConfirmation() {
        signInWithFixtureAccount()
        openInsights()
        let toggle = app.switches["cloudStatisticsToggle"]
        toggle.scrollUpUntilHittable(in: app, maxSwipes: 20)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let confirmEnable = app.buttons["confirmEnableCloudStatisticsButton"].firstMatch
        XCTAssertTrue(confirmEnable.waitForExistence(timeout: 8))
        confirmEnable.tap()

        let deleteButton = app.buttons["deleteCloudStatisticsButton"]
        deleteButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let confirmDelete = app.buttons["confirmDeleteCloudStatisticsButton"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 8))
        confirmDelete.tap()
        // The toggle itself is left as the user set it (delete never implicitly disables
        // future uploads) — only the alert confirming the deletion is expected next.
        XCTAssertTrue(app.alerts["Cloud Statistics"].waitForExistence(timeout: 5))
    }
}
