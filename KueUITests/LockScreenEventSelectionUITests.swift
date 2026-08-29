//
//  LockScreenEventSelectionUITests.swift
//  KueUITests
//
//  Post-Phase-12 fix — app-managed Lock Screen widget event selection. Tapping the real system
//  Lock Screen widget itself is outside XCTest's supported automation surface (same confirmed
//  limitation `SystemIntegrationSettingsUITests.swift`'s own header documents for `kue://` deep
//  links generally) — left as a documented manual verification step, not fabricated here.
//  Everything else this feature adds is reachable, and tested, through Settings → Widgets →
//  Lock Screen Event, and the widget's own deep link is exercised via a launch-argument
//  simulation (`UITestLaunchConfiguration.openLockScreenSelectionArgument`).
//

import XCTest

final class LockScreenEventSelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
    }

    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument] + extraArguments
        app.launch()
    }

    private func createEvent(title: String) {
        app.openManualAddForm()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()
        app.selectTab("tab-home")
    }

    private func openSelectorFromSettings() {
        app.selectTab("tab-settings")
        // Same pre-existing SwiftUI `Form`-materialization issue `scrollUpUntilHittable`'s own
        // Phase 7 doc comment documents — the Widgets section sits below what's rendered on
        // first appearance.
        let link = app.buttons["lockScreenEventSettingsLink"]
        link.scrollUpUntilHittable(in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    // MARK: 1. Opening the selector from a launch-argument-simulated widget deep link

    func testOpeningFromTheSimulatedWidgetDeepLinkShowsTheSelectionPage() {
        launch(extraArguments: [UITestLaunchConfiguration.openLockScreenSelectionArgument])
        XCTAssertTrue(app.navigationBars["Lock Screen Event"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No event selected"].waitForExistence(timeout: 5))
    }

    // MARK: 2/3. Selecting an event, seeing the current selection

    func testSelectingAnEventShowsItAsTheCurrentSelection() {
        launch()
        let title = uniqueTitle("Lock Screen Pick")
        createEvent(title: title)

        openSelectorFromSettings()
        // Rows are identified by event UUID (`lockScreenEventOption-<uuid>`), not title — this
        // page never knows the UUID up front, so it finds the row by its visible label instead.
        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // Selecting dismisses back to Settings — reopen to confirm the summary updated.
        openSelectorFromSettings()
        XCTAssertTrue(app.staticTexts["Currently Selected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    // MARK: 4. Changing the selected event

    func testChangingTheSelectionReplacesTheCurrentEvent() {
        launch()
        let first = uniqueTitle("First Pick")
        let second = uniqueTitle("Second Pick")
        createEvent(title: first)
        createEvent(title: second)

        openSelectorFromSettings()
        app.staticTexts[first].firstMatch.tap()

        openSelectorFromSettings()
        app.staticTexts[second].firstMatch.tap()

        openSelectorFromSettings()
        XCTAssertTrue(app.staticTexts[second].waitForExistence(timeout: 5))
    }

    // MARK: 5. Clearing the selection

    func testClearingTheSelectionReturnsToNoSelection() {
        launch()
        let title = uniqueTitle("To Clear")
        createEvent(title: title)

        openSelectorFromSettings()
        app.staticTexts[title].firstMatch.tap()

        openSelectorFromSettings()
        let clearButton = app.buttons["clearLockScreenSelectionButton"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
        clearButton.tap()
        app.buttons["Clear Selection"].firstMatch.tap() // confirmation dialog

        XCTAssertTrue(app.staticTexts["No event selected"].waitForExistence(timeout: 5))
    }

    // MARK: 6. Searching within the selector

    func testSearchingFiltersToMatchingEvents() {
        launch()
        let match = uniqueTitle("Findable Meeting")
        let other = uniqueTitle("Different Trip")
        createEvent(title: match)
        createEvent(title: other)

        openSelectorFromSettings()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Findable")

        XCTAssertTrue(app.staticTexts[match].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[other].exists)
    }

    // MARK: 7. Seeing the unavailable/deleted-selection explanation

    func testDeletedSelectionShowsAnUnavailableExplanation() {
        launch()
        let title = uniqueTitle("Will Be Deleted")
        createEvent(title: title)

        openSelectorFromSettings()
        app.staticTexts[title].firstMatch.tap()

        // Delete the event via Event Detail.
        app.selectTab("tab-home")
        app.revealHomeEventIfInsideCollapsedCompletedSection(titled: title)
        app.staticTexts[title].firstMatch.tap()
        let deleteButton = app.buttons["deleteEventButton"]
        deleteButton.scrollUpUntilHittable(in: app)
        deleteButton.tap()
        app.buttons["confirmDeleteButton"].firstMatch.tap()

        openSelectorFromSettings()
        XCTAssertTrue(app.staticTexts["The selected event is no longer available."].waitForExistence(timeout: 5))
    }

    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }
}
