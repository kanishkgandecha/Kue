//
//  CalendarIntegrationUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration, requirement 42: focused simulator UI tests
//  for Calendar settings/authorization presentation, contextual permission education, denied/
//  restricted states, import selection, editable imported draft, confirmation, export
//  confirmation, update presentation, missing-event handling, and conflict handling.
//
//  Every case launches with `UITestLaunchConfiguration.isolatedStoreArgument` (same isolated,
//  per-launch-wiped store as every other `KueUITests` class) plus
//  `fakeCalendarArgument` (and, where a specific test needs it, one of the state/fixture
//  override arguments) — `KueApp` installs a `FakeCalendarProvider` instead of
//  `SystemCalendarProvider` whenever that's present, so nothing here ever touches the real
//  EventKit database (requirement 43/44).
//

import XCTest

final class CalendarIntegrationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
    }

    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeCalendarArgument] + extraArguments
        app.launch()
    }

    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    private func createEvent(title: String) {
        app.buttons["addEventButton"].tap()
        let titleField = app.textFields["eventTitleField"]
        // A longer wait here than elsewhere in this file: this is the one flow where a sheet's
        // dismissal (the Calendar import list) and a second sheet's presentation (the prefilled
        // form) chain together, which needs more real wall-clock time than a single sheet
        // presentation does.
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    // MARK: 1. Calendar settings and authorization presentation

    func testSettingsShowsFullAccessAuthorizationState() {
        launch()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarStatusFullAccess").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 2. Contextual permission education

    func testImportSheetShowsPermissionEducationBeforeRequestingAccessWhenNotDetermined() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarNotDeterminedArgument])
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["importFromCalendarButton"].tap()
        // The button's own presence is itself proof this state (not denied/restricted/
        // unavailable/full-access) is what's showing.
        let requestAccessButton = app.buttons["importRequestAccessButton"]
        XCTAssertTrue(requestAccessButton.waitForExistence(timeout: 5))
        // Requesting access here is the deliberate, contextual action itself.
        requestAccessButton.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarImportList").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 3. Denied and restricted states

    func testSettingsShowsDeniedState() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarDeniedArgument])
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarStatusDenied").firstMatch.waitForExistence(timeout: 5))
    }

    func testImportSheetShowsUnavailableStateWhenDenied() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarDeniedArgument])
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["importFromCalendarButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarImportUnavailableState").firstMatch.waitForExistence(timeout: 5))
    }

    func testSettingsShowsRestrictedState() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarRestrictedArgument])
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarStatusRestricted").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 4. Import selection

    func testImportListShowsFixtureCalendarEvents() {
        launch()
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["importFromCalendarButton"].tap()
        XCTAssertTrue(app.staticTexts["Fake Calendar Meeting"].waitForExistence(timeout: 5))
    }

    // MARK: 5/6. Editable imported draft + explicit confirmation

    func testSelectingAnEventPresentsAnEditableDraftAndOnlySavesOnExplicitConfirmation() {
        launch()
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["importFromCalendarButton"].tap()
        XCTAssertTrue(app.staticTexts["Fake Calendar Meeting"].waitForExistence(timeout: 5))
        app.staticTexts["Fake Calendar Meeting"].tap()

        // The draft is presented pre-filled but still editable (requirement 12) — nothing has
        // been created yet (requirement 13).
        let titleField = app.textFields["eventTitleField"]
        // A longer wait here than elsewhere in this file: this is the one flow where a sheet's
        // dismissal (the Calendar import list) and a second sheet's presentation (the prefilled
        // form) chain together, which needs more real wall-clock time than a single sheet
        // presentation does.
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, "Fake Calendar Meeting")

        // Cancelling must leave nothing behind.
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Fake Calendar Meeting"].waitForExistence(timeout: 2))

        // Re-import, edit the still-open draft, and only now explicitly confirm.
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["importFromCalendarButton"].tap()
        XCTAssertTrue(app.staticTexts["Fake Calendar Meeting"].waitForExistence(timeout: 5))
        app.staticTexts["Fake Calendar Meeting"].tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        let editedTitle = uniqueTitle("Fake Calendar Meeting Edited")
        titleField.tap()
        titleField.typeText(" Edited")
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts["Fake Calendar Meeting Edited"].waitForExistence(timeout: 5))
        _ = editedTitle // documents intent; exact suffix asserted via the literal label above
    }

    // MARK: 7. Export confirmation

    func testAddToCalendarPresentsDestinationPickerAndLinksOnSelection() {
        launch()
        let title = uniqueTitle("UI Test Export")
        createEvent(title: title)
        app.staticTexts[title].tap()

        XCTAssertTrue(app.buttons["addToCalendarButton"].waitForExistence(timeout: 5))
        app.buttons["addToCalendarButton"].tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarDestinationList").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fake Calendar Home"].waitForExistence(timeout: 5))
        app.staticTexts["Fake Calendar Home"].tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusLinked").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 8. Update presentation

    func testUpdateCalendarEventShowsConfirmationDialog() {
        launch()
        let title = uniqueTitle("UI Test Update")
        createEvent(title: title)
        app.staticTexts[title].tap()
        app.buttons["addToCalendarButton"].tap()
        app.staticTexts["Fake Calendar Home"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusLinked").firstMatch.waitForExistence(timeout: 5))

        app.buttons["updateCalendarEventButton"].tap()
        // `.confirmationDialog` duplicates its action button in the accessibility tree (a
        // SwiftUI quirk, not app behavior — see EventManagementUITests's own note); `.firstMatch`
        // avoids an ambiguous-match error.
        XCTAssertTrue(app.buttons["confirmUpdateCalendarEventButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["confirmUpdateCalendarEventButton"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusLinked").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 9. Missing-event handling

    func testMissingLinkedEventOffersRecreateOrUnlink() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarPreLinkedMissingArgument])
        app.staticTexts["Fake Prelinked Missing Event"].tap()

        app.buttons["updateCalendarEventButton"].tap()
        XCTAssertTrue(app.buttons["recreateCalendarEventButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["unlinkFromMissingDialogButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["recreateCalendarEventButton"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusLinked").firstMatch.waitForExistence(timeout: 5))
    }

    func testMissingLinkedEventCanBeUnlinkedWithoutRecreating() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarPreLinkedMissingArgument])
        app.staticTexts["Fake Prelinked Missing Event"].tap()

        app.buttons["updateCalendarEventButton"].tap()
        XCTAssertTrue(app.buttons["unlinkFromMissingDialogButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["unlinkFromMissingDialogButton"].firstMatch.tap()

        XCTAssertTrue(app.buttons["addToCalendarButton"].waitForExistence(timeout: 5))
    }

    // MARK: 10. Conflict handling

    func testExternallyModifiedLinkedEventShowsConflictAndRequiresExplicitOverwrite() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeCalendarPreLinkedConflictArgument])
        app.staticTexts["Fake Prelinked Conflict Event"].tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusExternallyModified").firstMatch.waitForExistence(timeout: 5))

        app.buttons["updateCalendarEventButton"].tap()
        XCTAssertTrue(app.buttons["overwriteCalendarEventButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["overwriteCalendarEventButton"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "calendarLinkStatusLinked").firstMatch.waitForExistence(timeout: 5))
    }
}
