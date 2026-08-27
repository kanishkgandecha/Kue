//
//  RecurringEventsUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 3 — focused simulator UI tests per docs/17-recurring-events.md: creating each
//  recurrence type, the recurrence summary, validation errors, This Occurrence / This and
//  Future Occurrences editing, skip, complete, and delete (single occurrence and series) with
//  its scope confirmation. Same conventions as EventManagementUITests/TemplateAndScheduleUITests:
//  unique per-run titles (the app's real on-disk store persists across UI test runs), no
//  DatePicker/Picker-wheel interaction — Stepper/segmented/menu controls only.
//

import XCTest

private extension XCUIElement {
    func clearAndType(_ text: String) {
        // A plain `.tap()` taps the field's *center*, which for a field already containing
        // text doesn't reliably place the cursor at the end — confirmed empirically: deleting
        // `value.count` characters backward from a mid-field cursor only clears the front
        // portion, leaving a stray suffix of the old value that the newly typed text then
        // gets inserted *before*. Tapping near the field's right edge reliably lands the
        // cursor at the end instead, so backward deletes actually clear everything.
        coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = value as? String, !value.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            typeText(deleteString)
        }
        typeText(text)
    }
}

final class RecurringEventsUITests: XCTestCase {
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

    private func openAddForm() {
        app.buttons["addEventButton"].tap()
        XCTAssertTrue(app.textFields["eventTitleField"].waitForExistence(timeout: 5))
    }

    private func enterTitle(_ title: String) {
        let titleField = app.textFields["eventTitleField"]
        titleField.tap()
        titleField.typeText(title)
    }

    private func tapSave() {
        app.buttons["saveEventButton"].tap()
    }

    /// The "Repeat" section sits well below "Quick Add"/"Event"/"When"/"Details" in the form,
    /// and SwiftUI's `Form` (a lazily-rendered list) doesn't put an off-screen row's
    /// accessibility element in the tree until it's actually scrolled into view —
    /// `waitForExistence` alone never finds it. A full-screen `app.swipeUp()` easily overshoots
    /// a short run of newly-revealed rows (scrolling them past the top of the viewport before
    /// this ever checks `.exists`), so this uses a smaller, controlled drag instead — enough
    /// attempts to reach the bottom of the form, small enough per step not to skip past it.
    @discardableResult
    private func scrollUntilExists(_ element: XCUIElement, maxAttempts: Int = 10) -> Bool {
        var attempts = 0
        while !element.exists && attempts < maxAttempts {
            app.swipeUp()
            // SwiftUI's Form inserts newly-revealed rows (e.g. right after toggling
            // "Repeats" on) with a brief layout/animation settle that XCUITest's own
            // idle-wait doesn't always cover — a short pause avoids racing that.
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
        return element.exists
    }

    /// Toggles "Repeats" on — the default rule underneath (weekly, never-ending) is already
    /// valid, so most tests only need to change what they're specifically exercising.
    ///
    /// A plain `.tap()` on this element taps the *center* of the combined label+switch
    /// accessibility row, which — for this particular Toggle — lands on the label side rather
    /// than ever actually flipping the native switch underneath (confirmed empirically: the
    /// row's own `value` never changed after `.tap()`, even though the element and its frame
    /// were both correctly resolved). Tapping a coordinate on the switch's own side of the row
    /// (near its right edge, where the actual widget renders) reliably toggles it instead.
    private func enableRecurrence() {
        let toggle = app.switches["recurrenceToggle"]
        XCTAssertTrue(scrollUntilExists(toggle))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func selectFrequency(_ name: String) {
        let picker = app.buttons["recurrenceFrequencyPicker"]
        XCTAssertTrue(scrollUntilExists(picker))
        picker.tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.buttons[name].tap()
    }

    /// Home's real on-disk store persists across every UI test run in this whole target, and
    /// a freshly created zero-duration event whose `startDate` defaults to "now" is often
    /// already `.completed` by the time `save()` actually runs (a few seconds have elapsed
    /// since the form opened) — landing it in Home's "Completed" section, which — after many
    /// prior runs have accumulated a growing "Upcoming" section above it (this suite's own
    /// recurring series produce genuinely-future occurrences) — is reliably scrolled out of
    /// the accessibility tree's lazily-rendered view. Rather than fight that with more
    /// scrolling, this searches for the event by its own unique title first: Home's search
    /// (`.searchable`, docs/16-search-and-organization.md) switches to a small, flat, always
    /// fully-rendered "Results" list, independent of section/scroll position.
    private func search(_ title: String) {
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(title)
    }

    // MARK: - Creating each recurrence type (requirement: "creating each recurrence type")

    func testCreatingAWeeklyRecurringEventShowsTheSummaryAndSaves() {
        let title = uniqueTitle("UI Test Weekly Standup")
        openAddForm()
        enterTitle(title)
        enableRecurrence()

        // Default frequency is weekly, interval 1, never-ending.
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Every week"]))

        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testCreatingADailyRecurringEventWithAnOccurrenceCountEnd() {
        let title = uniqueTitle("UI Test Daily Habit")
        openAddForm()
        enterTitle(title)
        enableRecurrence()
        selectFrequency("Day")

        let afterOption = app.segmentedControls.buttons["After"]
        XCTAssertTrue(scrollUntilExists(afterOption))
        afterOption.tap()
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Every day, 10 times"]))

        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testCreatingAMonthlyRecurringEventWithAnEndDate() {
        let title = uniqueTitle("UI Test Monthly Report")
        openAddForm()
        enterTitle(title)
        enableRecurrence()
        selectFrequency("Month")

        let onDateOption = app.segmentedControls.buttons["On Date"]
        XCTAssertTrue(scrollUntilExists(onDateOption))
        onDateOption.tap()
        XCTAssertTrue(scrollUntilExists(app.datePickers["recurrenceEndDatePicker"]))
        // Default end-date value is already valid (30 days out) — not interacting with the
        // DatePicker itself, per this suite's convention.
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Every month until'")).firstMatch
        XCTAssertTrue(scrollUntilExists(summary))

        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testCreatingAYearlyRecurringEvent() {
        let title = uniqueTitle("UI Test Yearly Anniversary")
        openAddForm()
        enterTitle(title)
        enableRecurrence()
        selectFrequency("Year")

        XCTAssertTrue(scrollUntilExists(app.staticTexts["Every year"]))
        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    // MARK: - Validation errors (requirement: "validation errors")

    func testEmptyTitleStillBlocksSaveEvenWhileRecurring() {
        openAddForm()
        enableRecurrence()
        // No title entered — save must be blocked exactly as it already is for a
        // non-recurring event, with the recurrence section still visible above the error.
        tapSave()
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Give this event a title."]))
    }

    // MARK: - Editing scope (requirements: "editing one occurrence" / "editing this and future occurrences")

    /// Creates a weekly series and leaves Home's search filtered to it, ready for the caller
    /// to tap into a specific occurrence.
    private func createWeeklySeries(title: String) {
        openAddForm()
        enterTitle(title)
        enableRecurrence()
        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15))
    }

    /// Every materialized occurrence in a series shares the exact same title, so a plain
    /// `app.staticTexts[title]` (a single-element lookup) is ambiguous once more than one row
    /// matches — `.tap()` on an ambiguous match fails. Each row's own *button* combines title
    /// and date into one label (e.g. "Standup, Generic · 3 Sep 2026 at 9:00 AM"), which is
    /// what actually distinguishes one occurrence from its siblings; matching on that instead
    /// of the bare title also lets callers identify one exact occurrence, not just "a" one.
    private func occurrenceRows(titled title: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
    }

    private func tapFirstOccurrence(titled title: String) {
        occurrenceRows(titled: title).firstMatch.tap()
    }

    /// Reaching the recurrence controls scrolls well past the title field at the very top of
    /// the form — far enough that it falls out of the lazily-rendered range entirely. Scrolls
    /// back up until it's confirmed visible again, the same verify-don't-guess approach
    /// `scrollUntilExists` uses for the opposite direction.
    @discardableResult
    private func scrollUpUntilExists(_ element: XCUIElement, maxAttempts: Int = 20) -> Bool {
        var attempts = 0
        while !element.exists && attempts < maxAttempts {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
        return element.exists
    }

    func testEditingThisOccurrenceOnlyRenamesTheOneOpened() {
        let title = uniqueTitle("UI Test Scope This")
        createWeeklySeries(title: title)

        tapFirstOccurrence(titled: title)
        XCTAssertTrue(app.buttons["editEventButton"].waitForExistence(timeout: 5))
        app.buttons["editEventButton"].tap()

        // A series occurrence's edit form shows the scope picker instead of a plain toggle.
        XCTAssertTrue(scrollUntilExists(app.segmentedControls["recurrenceEditScopePicker"]))
        // "This Occurrence" is the default selection — no tap needed.
        let renamed = "\(title) (this one)"
        XCTAssertTrue(scrollUpUntilExists(app.textFields["eventTitleField"]))
        app.textFields["eventTitleField"].clearAndType(renamed)
        tapSave()

        // Saving an edit returns to this occurrence's own Event Detail screen (not Home) —
        // its nav title now reads the renamed value.
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 5))
        // Back on Home (still search-filtered): at least one sibling occurrence keeps the
        // original title — unrelated occurrences were never mutated by a This-Occurrence edit.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    func testEditingThisAndFutureOccurrencesOffersTheScopeAndSaves() {
        let title = uniqueTitle("UI Test Scope Future")
        createWeeklySeries(title: title)

        tapFirstOccurrence(titled: title)
        app.buttons["editEventButton"].tap()

        XCTAssertTrue(scrollUntilExists(app.segmentedControls["recurrenceEditScopePicker"]))
        app.segmentedControls.buttons["This and Future Occurrences"].tap()
        // Choosing this scope reveals the editable recurrence controls, pre-filled.
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Every week"]))

        let renamed = "\(title) (future)"
        XCTAssertTrue(scrollUpUntilExists(app.textFields["eventTitleField"]))
        app.textFields["eventTitleField"].clearAndType(renamed)
        tapSave()

        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 15))
    }

    // MARK: - Skip (requirement: "skipping an occurrence")

    func testSkippingAnOccurrenceShowsTheUnskipAction() {
        let title = uniqueTitle("UI Test Skip")
        createWeeklySeries(title: title)

        tapFirstOccurrence(titled: title)
        XCTAssertTrue(scrollUntilExists(app.buttons["skipOccurrenceButton"]))
        app.buttons["skipOccurrenceButton"].tap()

        XCTAssertTrue(scrollUntilExists(app.buttons["unskipOccurrenceButton"]))
    }

    // MARK: - Complete (requirement: "completing an occurrence")

    func testCompletingAnOccurrenceMarksItComplete() {
        let title = uniqueTitle("UI Test Complete Occurrence")
        createWeeklySeries(title: title)

        tapFirstOccurrence(titled: title)
        XCTAssertTrue(scrollUntilExists(app.buttons["completeEventButton"]))
        app.buttons["completeEventButton"].tap()

        XCTAssertTrue(scrollUntilExists(app.buttons["Mark Not Complete"]))
    }

    // MARK: - Delete (requirements: "deleting an occurrence or series" / "confirming destructive scope")

    func testDeleteConfirmationOffersBothScopesForASeriesOccurrenceAndDeletingOneRemovesJustThatOne() {
        let title = uniqueTitle("UI Test Delete Scope")
        createWeeklySeries(title: title)

        // Each occurrence's row button combines title + its own date into one label — capture
        // exactly which occurrence we're about to delete so this can prove *only* that one is
        // gone afterward, regardless of how many total occurrences the series has.
        let targetRow = occurrenceRows(titled: title).firstMatch
        XCTAssertTrue(targetRow.waitForExistence(timeout: 5))
        let deletedRowLabel = targetRow.label

        targetRow.tap()
        XCTAssertTrue(scrollUntilExists(app.buttons["deleteEventButton"]))
        app.buttons["deleteEventButton"].tap()

        // Both destructive options are offered, each naming its own scope.
        XCTAssertTrue(app.buttons["confirmDeleteOccurrenceButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirmDeleteThisAndFutureButton"].firstMatch.waitForExistence(timeout: 5))

        app.buttons["confirmDeleteOccurrenceButton"].firstMatch.tap()

        // Back on Home (still search-active/filtered to this series' title — search staying
        // focused across the navigation pop means the standard "Kue" nav bar doesn't
        // necessarily reappear, so this doesn't depend on it): the exact occurrence deleted is
        // gone, but the series continues — a sibling occurrence still matches.
        XCTAssertTrue(occurrenceRows(titled: title).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[deletedRowLabel].waitForExistence(timeout: 3))
    }

    func testDeletingANonRecurringEventStillShowsTheSingleDeleteButton() {
        let title = uniqueTitle("UI Test Delete Plain")
        openAddForm()
        enterTitle(title)
        tapSave()
        search(title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))

        tapFirstOccurrence(titled: title)
        XCTAssertTrue(scrollUntilExists(app.buttons["deleteEventButton"]))
        app.buttons["deleteEventButton"].tap()
        // A plain event's dialog keeps its original single "Delete" action, not the two-scope
        // series dialog.
        XCTAssertFalse(app.buttons["confirmDeleteOccurrenceButton"].waitForExistence(timeout: 2))
        app.buttons["confirmDeleteButton"].firstMatch.tap()

        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 2))
    }
}
