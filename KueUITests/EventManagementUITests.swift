//
//  EventManagementUITests.swift
//  KueUITests
//
//  Targeted flows per docs/10-testing-strategy.md "UI tests" — create, edit, archive,
//  delete. Deliberately doesn't touch DatePicker/Picker wheels (default field values are
//  used) to keep these flows fast and non-flaky; field-level correctness is covered by
//  EventValidatorTests/EventStatusEngineTests instead.
//

import XCTest

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            typeText(deleteString)
        }
        typeText(text)
    }
}

// `scrollUpUntilHittable(in:maxSwipes:)` moved to `UITestLaunchConfiguration.swift` once more
// than this one file needed it (Event Detail's "Actions" section — Calendar/Duplicate/Delete —
// isn't always already materialized/hittable the instant the detail view appears).

final class EventManagementUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument]
        app.launch()
    }

    private func createEvent(title: String) {
        app.openManualAddForm()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()
        // Kue 2.0 Phase 7 — saving dismisses back to the Add tab, not Home; every caller below
        // immediately looks for the new event's row, so land back on Home the same way a user
        // would.
        app.selectTab("tab-home")
        app.revealHomeEventIfInsideCollapsedCompletedSection(titled: title)
    }

    /// Unique per invocation — the app's real on-disk store persists across UI test runs,
    /// so fixed titles would collide (and ambiguously match) on a rerun.
    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    func testCreateEventAppearsOnHome() {
        let title = uniqueTitle("UI Test Interview")
        createEvent(title: title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    func testEditEventUpdatesTitle() {
        let originalTitle = uniqueTitle("UI Test Exam")
        let newTitle = "\(originalTitle) Renamed"
        createEvent(title: originalTitle)

        app.staticTexts[originalTitle].tap()
        app.buttons["editEventButton"].tap()

        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.clearAndType(newTitle)
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts[newTitle].waitForExistence(timeout: 5))
    }

    func testArchiveEventRemovesItFromHome() {
        let title = uniqueTitle("UI Test Deadline")
        createEvent(title: title)

        app.staticTexts[title].tap()
        app.buttons["archiveEventButton"].tap()
        XCTAssertTrue(app.buttons["unarchiveEventButton"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap() // back to Home
        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 2))
    }

    func testDeleteEventRemovesItFromHome() {
        let title = uniqueTitle("UI Test Trip")
        createEvent(title: title)

        app.staticTexts[title].tap()
        let deleteButton = app.buttons["deleteEventButton"]
        deleteButton.scrollUpUntilHittable(in: app)
        deleteButton.tap()
        // `.confirmationDialog` duplicates its action button in the accessibility tree
        // (a SwiftUI quirk, not app behavior) — `.firstMatch` avoids an ambiguous-match error.
        app.buttons["confirmDeleteButton"].firstMatch.tap()

        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 2))
    }
}
