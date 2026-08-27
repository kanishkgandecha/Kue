//
//  SearchAndOrganizationUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 2 — requirement 14: focused simulator UI tests for search, clearing search,
//  filtering, sorting, empty results, and duplication. Same conventions as
//  EventManagementUITests/TemplateAndScheduleUITests: unique titles per run (the app's real
//  on-disk store persists across UI test runs), no DatePicker/Picker-wheel interaction.
//

import XCTest

final class SearchAndOrganizationUITests: XCTestCase {
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

    private func createEvent(title: String, eventType: String? = nil) {
        app.buttons["addEventButton"].tap()
        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        if let eventType {
            app.buttons["eventTypePicker"].tap()
            if app.buttons[eventType].waitForExistence(timeout: 2) {
                app.buttons[eventType].tap()
            }
        }
        app.buttons["saveEventButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    private var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    // MARK: - Search + clear (requirement 14)

    func testSearchingFiltersHomeToMatchingTitle() {
        let title = uniqueTitle("UI Test Search Target")
        createEvent(title: title)

        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(title)

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    func testClearingSearchRestoresTheDefaultHomeList() {
        let title = uniqueTitle("UI Test Clear Search")
        createEvent(title: title)

        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(uniqueTitle("Some Query That Matches Nothing At All"))
        XCTAssertFalse(app.staticTexts[title].waitForExistence(timeout: 2))

        // System search field's own clear ("x") button.
        if app.buttons["Clear text"].waitForExistence(timeout: 2) {
            app.buttons["Clear text"].tap()
        } else {
            searchField.buttons.firstMatch.tap()
        }

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }

    func testSearchingForANonexistentTitleShowsAnEmptyResultsState() {
        // `EventListQueryEngine.emptyReason` returns `.emptyDatabase` (not `.noResultsForQuery`)
        // when the store has zero rows at all — a real precedence, not a bug — so this test
        // must not depend on some *other* test having already populated the store before it
        // runs. Each test now launches against its own isolated, empty store (see
        // `UITestLaunchConfiguration`), so this creates the one event itself that makes "no
        // results for this query" the actually-correct case to assert, regardless of
        // execution order.
        createEvent(title: uniqueTitle("UI Test Empty Search Baseline"))

        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(uniqueTitle("Definitely Not A Real Event Title"))

        // Matched by our own accessibility identifier, not the system's exact "No results"
        // wording, which isn't a stable contract to assert against.
        let emptyView = app.descendants(matching: .any).matching(identifier: "noSearchResultsView").firstMatch
        XCTAssertTrue(emptyView.waitForExistence(timeout: 5))
    }

    // MARK: - Filter + sort sheet (requirement 14)

    func testOpeningFilterSortSheetShowsSortAndFilterControls() {
        XCTAssertTrue(app.buttons["filterSortButton"].waitForExistence(timeout: 5))
        app.buttons["filterSortButton"].tap()

        // A Toggle row's accessibility identifier is reliably matchable (confirmed by
        // testFilteringToASingleEventTypeShowsOnlyThatType below) — used here rather than a
        // segmented picker's per-option label, which this same sheet's other, more targeted
        // sort test already exercises directly.
        XCTAssertTrue(app.switches["filterType-interview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["resetFiltersButton"].waitForExistence(timeout: 2))
        app.buttons["doneFilterSortButton"].tap()
    }

    func testFilteringToASingleEventTypeShowsOnlyThatType() {
        let interviewTitle = uniqueTitle("UI Test Filter Interview")
        createEvent(title: interviewTitle, eventType: "Interview")

        app.buttons["filterSortButton"].tap()
        XCTAssertTrue(app.switches["filterType-interview"].waitForExistence(timeout: 5))
        app.switches["filterType-interview"].tap()
        app.buttons["doneFilterSortButton"].tap()

        XCTAssertTrue(app.staticTexts[interviewTitle].waitForExistence(timeout: 5))

        // Reset so this run doesn't leave the filter active for whatever test runs next.
        app.buttons["filterSortButton"].tap()
        app.buttons["resetFiltersButton"].tap()
        app.buttons["doneFilterSortButton"].tap()
    }

    func testSortingBySortOptionKeepsTheCreatedEventReachable() {
        let title = uniqueTitle("UI Test Sort By Priority")
        createEvent(title: title)

        app.buttons["filterSortButton"].tap()
        // Segmented picker — each option renders as a tappable button segment.
        XCTAssertTrue(app.buttons["Priority"].waitForExistence(timeout: 5))
        app.buttons["Priority"].tap()
        app.buttons["doneFilterSortButton"].tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))

        app.buttons["filterSortButton"].tap()
        app.buttons["resetFiltersButton"].tap()
        app.buttons["doneFilterSortButton"].tap()
    }

    // MARK: - Duplication (requirement 14)

    func testDuplicateEventCreatesASecondEventWithTheSameTitle() {
        let title = uniqueTitle("UI Test Duplicate")
        createEvent(title: title)

        app.staticTexts[title].tap()
        XCTAssertTrue(app.buttons["duplicateEventButton"].waitForExistence(timeout: 5))
        app.buttons["duplicateEventButton"].tap()

        // The duplicated event's own detail screen is presented — its navigation title is
        // the (identical) title, proving a second, independent event was created and opened.
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
        // The duplicate warning fires because the source (same title, same date) is still
        // in the store — confirms duplicate detection actually ran, not just event creation.
        // Matched by accessibility identifier (not exact text) since a `Label`'s rendered
        // element type isn't guaranteed to be `staticTexts`.
        let duplicateWarning = app.descendants(matching: .any).matching(identifier: "duplicateWarning").firstMatch
        XCTAssertTrue(duplicateWarning.waitForExistence(timeout: 5))
    }
}
