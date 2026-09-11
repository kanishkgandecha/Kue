//
//  HonestOutcomesUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 10.1 — docs/25-honest-event-outcomes-and-reminders.md "N." A freshly created
//  manual event defaults to `.generic` (zero-duration, per docs/04) with `startDate == .now`
//  (`EventDraft`'s own defaults), so its `effectiveEndDate` is already in the past the moment
//  it's saved — the same fact `EventManagementUITests.createEvent`'s own helper comment
//  already relies on, reused here to reliably reach Awaiting Outcome with no artificial delay
//  or DatePicker interaction (matching this suite's own "no DatePicker wheels" convention).
//

import XCTest

final class HonestOutcomesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument]
        app.launch()
    }

    private func uniqueTitle(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Creates a default (`.generic`, zero-duration, `startDate == .now`) event, which reaches
    /// Awaiting Outcome essentially immediately — see this file's own header.
    private func createAwaitingOutcomeEvent(title: String) {
        app.openManualAddForm()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()
        app.selectTab("tab-home")
    }

    private func needsAttentionButton(_ identifierPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(identifierPrefix)-")).firstMatch
    }

    // MARK: - Home: Needs Attention section

    func testNeedsAttentionSectionAppearsForAnUnresolvedPastEvent() {
        let title = uniqueTitle("UI Test Needs Attention")
        createAwaitingOutcomeEvent(title: title)

        // The event itself renders (proving the section isn't hidden/collapsed), and its row
        // offers the Needs Attention action set — the functional proof the section exists,
        // more reliable than asserting on a `Section`'s own accessibility element (which,
        // like `DisclosureGroup` elsewhere in this codebase, doesn't reliably resolve to one
        // queryable element type).
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(needsAttentionButton("needsAttentionComplete").waitForExistence(timeout: 5))
    }

    func testMarkCompletedFromNeedsAttentionRemovesItFromNeedsAttention() {
        let title = uniqueTitle("UI Test Mark Completed")
        createAwaitingOutcomeEvent(title: title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))

        let completeButton = needsAttentionButton("needsAttentionComplete")
        XCTAssertTrue(completeButton.waitForExistence(timeout: 5))
        completeButton.tap()

        // No longer offering Needs Attention actions for this event — it moved to Completed.
        XCTAssertFalse(needsAttentionButton("needsAttentionComplete").waitForExistence(timeout: 3))
    }

    func testCancelFromNeedsAttentionCancelsWithNoConfirmationDialog() {
        let title = uniqueTitle("UI Test Needs Attention Cancel")
        createAwaitingOutcomeEvent(title: title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))

        let cancelButton = needsAttentionButton("needsAttentionCancel")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        // Kue 2.0 Phase 10.1 (docs/25 "D."): Cancel is a direct call, same precedent as every
        // other Cancel button in the app — no blocking confirmation dialog should ever appear.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(needsAttentionButton("needsAttentionCancel").waitForExistence(timeout: 3))
    }

    // MARK: - Event Detail: outcome card

    func testOutcomeCardAppearsOnEventDetailForAnAwaitingOutcomeEvent() {
        let title = uniqueTitle("UI Test Outcome Card")
        createAwaitingOutcomeEvent(title: title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.staticTexts[title].tap()

        XCTAssertTrue(app.buttons["outcomeCompletedButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["outcomeRescheduleButton"].exists)
        XCTAssertTrue(app.buttons["outcomeCancelledButton"].exists)
        XCTAssertTrue(app.staticTexts["outcomeTimingDescription"].exists)
    }

    func testMarkCompletedFromOutcomeCardDismissesTheCard() {
        let title = uniqueTitle("UI Test Outcome Complete")
        createAwaitingOutcomeEvent(title: title)
        app.staticTexts[title].tap()

        let completeButton = app.buttons["outcomeCompletedButton"]
        XCTAssertTrue(completeButton.waitForExistence(timeout: 5))
        completeButton.tap()

        XCTAssertFalse(app.buttons["outcomeCompletedButton"].waitForExistence(timeout: 3))
    }

    func testRescheduleFromOutcomeCardOpensTheExistingEditForm() {
        let title = uniqueTitle("UI Test Outcome Reschedule")
        createAwaitingOutcomeEvent(title: title)
        app.staticTexts[title].tap()

        let rescheduleButton = app.buttons["outcomeRescheduleButton"]
        XCTAssertTrue(rescheduleButton.waitForExistence(timeout: 5))
        rescheduleButton.tap()

        // Same `EventFormView(mode: .edit(event))` sheet every other edit entry point opens —
        // its title field is prefilled with the existing title, not cleared.
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, title)
    }

    func testCancelFromOutcomeCardHasNoConfirmationDialog() {
        let title = uniqueTitle("UI Test Outcome Cancel")
        createAwaitingOutcomeEvent(title: title)
        app.staticTexts[title].tap()

        let cancelButton = app.buttons["outcomeCancelledButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["outcomeCompletedButton"].waitForExistence(timeout: 3))
    }

    // MARK: - Settings: reminder preference control

    func testReminderDurationPickerIsPresentInNotificationSettings() {
        app.selectTab("tab-settings")
        // `.any` — a SwiftUI `Picker` inline in a `Form` can surface as a button, a static
        // text row, or another element type depending on OS version; matching by identifier
        // across every type (not guessing one) is what stays robust here.
        let picker = app.descendants(matching: .any)["reminderDurationPicker"]
        // Kue 3.0 Phase 4's new Account section (Settings' first) pushed this row further
        // down — see `scrollUpUntilHittable`'s own header for the underlying `Form`
        // virtualization this works around.
        picker.scrollUpUntilHittable(in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
    }
}
