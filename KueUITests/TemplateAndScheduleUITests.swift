//
//  TemplateAndScheduleUITests.swift
//  KueUITests
//
//  Phase 6 (M5) — targeted flows per docs/10-testing-strategy.md "UI tests": template
//  selection and custom-rule editing. Same conventions as EventManagementUITests: default
//  field values wherever possible, no DatePicker/Picker-wheel interaction.
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

final class TemplateAndScheduleUITests: XCTestCase {
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

    // MARK: - Template selection (requirement 2/3: fully scheduled, zero AI)

    func testSelectingATemplateCreatesAFullyScheduledEvent() {
        app.buttons["templatesButton"].tap()

        let interviewTemplate = app.buttons["template-interview"]
        XCTAssertTrue(interviewTemplate.waitForExistence(timeout: 5))
        interviewTemplate.tap()

        // Requirement 2/3: the form opens pre-set to Interview — no separate step, no AI.
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))

        let title = uniqueTitle("UI Test Template Interview")
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()

        // Creation completes end to end and Templates' own sheet doesn't linger underneath
        // (a nested-sheet bug this test originally caught) — the new event is reachable.
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.staticTexts[title].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))

        // Full scheduling correctness for a future-dated Interview event (offsets, task
        // titles) is covered at the unit level — SchedulingEngineTests
        // .interviewTemplateMatchesSpec / .planProducesOneTaskPerRuleWhenNothingIsClamped.
        // This event's default start date is *now*, so its own built-in offsets are
        // correctly clamped away here, same as the manual-entry case.
    }

    // MARK: - Custom-rule editing (requirement 5)

    func testAddingACustomScheduleRuleAppearsInTheScheduleList() {
        // A fresh manual event defaults startDate to *now* — any "before" offset is
        // therefore already in the past and correctly clamped away from Tasks (see
        // CustomScheduleTests for that behavior at the unit level). This test stays scoped
        // to what Edit Schedule itself guarantees: the rule you add shows up in its list.
        app.buttons["addEventButton"].tap()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        let title = uniqueTitle("UI Test Custom Schedule")
        titleField.tap()
        titleField.typeText(title)
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.staticTexts[title].tap()
        app.segmentedControls.buttons["Timeline"].tap()

        app.buttons["customizeScheduleButton"].tap()
        XCTAssertTrue(app.buttons["addScheduleRuleButton"].waitForExistence(timeout: 5))
        app.buttons["addScheduleRuleButton"].tap()

        let ruleTitleField = app.textFields["scheduleRuleTitleField"]
        XCTAssertTrue(ruleTitleField.waitForExistence(timeout: 5))
        ruleTitleField.tap()
        ruleTitleField.typeText("Custom prep task")
        app.buttons["saveScheduleRuleButton"].tap()

        // Back on Edit Schedule — the new rule is listed, sorted (there's only one).
        XCTAssertTrue(app.staticTexts["Custom prep task"].waitForExistence(timeout: 5))
        app.buttons["saveScheduleButton"].tap()

        // Save completes and returns to Event Detail without hanging or erroring.
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    func testDeletingAScheduleRuleViaSwipe() {
        app.buttons["addEventButton"].tap()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        let title = uniqueTitle("UI Test Swipe Delete")
        titleField.tap()
        titleField.typeText(title)
        // Interview leaves multiple built-in rules to delete from.
        app.buttons["eventTypePicker"].tap()
        if app.buttons["Interview"].waitForExistence(timeout: 2) {
            app.buttons["Interview"].tap()
        }
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.staticTexts[title].tap()
        app.segmentedControls.buttons["Timeline"].tap()
        app.buttons["customizeScheduleButton"].tap()

        let list = app.collectionViews["scheduleRuleList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.swipeLeft()
        app.buttons["Delete"].tap()

        app.buttons["saveScheduleButton"].tap()
        // No crash / hang getting back to Event Detail is the main assertion here — exact
        // remaining-task content is covered at the unit level (CustomScheduleTests).
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }
}
