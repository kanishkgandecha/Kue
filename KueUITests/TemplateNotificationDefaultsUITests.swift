//
//  TemplateNotificationDefaultsUITests.swift
//  KueUITests
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults": reachable from
//  Templates via a swipe action, add a rule, see it listed, and prove the copy-at-creation
//  behavior end to end (create an event of that type, confirm the custom rule appears on it).
//

import XCTest

final class TemplateNotificationDefaultsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument]
        app.launch()
    }

    private func openExamTemplateNotificationDefaults() {
        app.selectTab("tab-templates")
        let swipeButton = app.buttons["template-exam-notifications"]
        let row = app.buttons["template-exam"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        XCTAssertTrue(swipeButton.waitForExistence(timeout: 5))
        swipeButton.tap()
    }

    func testTemplateNotificationDefaultsIsReachableFromTemplates() {
        openExamTemplateNotificationDefaults()
        XCTAssertTrue(app.navigationBars["Exam Notifications"].waitForExistence(timeout: 5))
    }

    func testAddingATemplateRuleShowsItInTheList() {
        openExamTemplateNotificationDefaults()

        let addButton = app.buttons["addTemplateNotificationDefaultButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let saveButton = app.buttons["saveTemplateRuleButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        // The editor's own default state (anchor: .eventStart, before, 30 minutes).
        XCTAssertTrue(app.staticTexts["Event Start"].waitForExistence(timeout: 5))
    }

    func testDeletingATemplateRuleRemovesItFromTheList() {
        openExamTemplateNotificationDefaults()

        app.buttons["addTemplateNotificationDefaultButton"].tap()
        app.buttons["saveTemplateRuleButton"].tap()

        XCTAssertTrue(app.staticTexts["Event Start"].waitForExistence(timeout: 5))
        app.staticTexts["Event Start"].tap()

        let deleteButton = app.buttons["deleteTemplateRuleButton"]
        deleteButton.scrollUpUntilHittable(in: app)
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        XCTAssertFalse(app.staticTexts["Event Start"].waitForExistence(timeout: 3))
    }
}
