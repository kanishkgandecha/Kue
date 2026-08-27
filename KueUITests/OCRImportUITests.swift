//
//  OCRImportUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input, requirement 47: focused simulator UI tests for
//  opening the OCR flow, on-device privacy disclosure, loading state, successful recognized-
//  text review, editing recognized text, low-confidence warning, no-text state, failure and
//  retry, choosing another image, cancelling, continuing into the existing parsing/confirmation
//  flow, and confirming the final event.
//
//  Every case launches with `UITestLaunchConfiguration.isolatedStoreArgument` plus
//  `fakeOCRArgument` (and, where a specific test needs it, one of the result-variant
//  arguments) — `KueApp` installs `FakeOCRTextRecognizer`/`FakeNLParser`/
//  `FakeAIAvailabilityChecker` instead of the real, Vision/Apple-Intelligence-backed
//  implementations whenever that's present, and `OCRImportView` swaps its real `PhotosPicker`
//  for a deterministic in-process fixture image — nothing here ever touches the real Photos
//  library or uncontrolled Vision/on-device-model output (requirement 45/48).
//

import XCTest

final class OCRImportUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
    }

    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeOCRArgument] + extraArguments
        app.launch()
    }

    private func openOCRFlow() {
        // Kue 2.0 Phase 6 collapsed Import from Calendar / Scan Screenshot / Voice Input into
        // one "More Ways to Add" menu once a third trailing toolbar item pushed the toolbar
        // into the system's own overflow "More" button — see HomeView's own comment.
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["scanScreenshotButton"].tap()
    }

    private func chooseFixtureImage() {
        app.buttons["ocrChooseFixtureImageButton"].tap()
    }

    // MARK: 1. Opening the OCR flow

    func testOpeningOCRFlowShowsInitialState() {
        launch()
        openOCRFlow()
        XCTAssertTrue(app.buttons["ocrChooseFixtureImageButton"].waitForExistence(timeout: 5))
    }

    // MARK: 2. On-device privacy disclosure

    func testOnDevicePrivacyDisclosureIsShown() {
        launch()
        openOCRFlow()
        // Requirement 21/22 — matched by its exact, specific copy (not just "on-device" in the
        // abstract): the image is processed locally and is never uploaded by Kue.
        let disclosureText = "Processed on-device. The image you select is processed locally on this device and is never uploaded by Kue."
        XCTAssertTrue(app.staticTexts[disclosureText].waitForExistence(timeout: 5))
    }

    // MARK: 3. Loading state

    func testLoadingStateAppearsWhileProcessing() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        // The fake recognizer has a deliberate short artificial delay specifically so this is
        // reliably observable — see `FakeOCRTextRecognizer.artificialDelayNanoseconds`.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ocrLoadingState").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 4. Successful recognized-text review

    func testSuccessfulRecognizedTextReview() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ocrReviewingState").firstMatch.waitForExistence(timeout: 5))
        let editor = app.textViews["ocrRecognizedTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Fake OCR Screenshot Interview") ?? false)
    }

    // MARK: 5. Editing recognized text

    func testEditingRecognizedText() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        let editor = app.textViews["ocrRecognizedTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Edited")
        XCTAssertTrue((editor.value as? String)?.contains("Edited") ?? false)
    }

    // MARK: 6. Low-confidence warning

    func testLowConfidenceWarningShown() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeOCRLowConfidenceArgument])
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ocrLowConfidenceWarning").firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: 7. No-text state

    func testNoTextFoundState() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeOCRNoTextArgument])
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.staticTexts["No text was found in that image. Try a clearer photo, or add this event manually."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ocrChooseAnotherPhotoButton"].waitForExistence(timeout: 2))
    }

    // MARK: 8. Failure and retry

    func testFailureAndRetry() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeOCRFailureArgument])
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.buttons["ocrChooseAnotherPhotoButton"].waitForExistence(timeout: 5))
        app.buttons["ocrChooseAnotherPhotoButton"].tap()
        XCTAssertTrue(app.buttons["ocrChooseFixtureImageButton"].waitForExistence(timeout: 5))
    }

    // MARK: 9. Choosing another image

    func testChoosingAnotherImageFromReviewReturnsToInitialState() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.buttons["ocrTryAnotherPhotoButton"].waitForExistence(timeout: 5))
        app.buttons["ocrTryAnotherPhotoButton"].tap()
        XCTAssertTrue(app.buttons["ocrChooseFixtureImageButton"].waitForExistence(timeout: 5))
    }

    // MARK: 10. Cancelling

    func testCancellingFromInitialStateReturnsToHomeWithNoEventCreated() {
        launch()
        openOCRFlow()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addEventButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fake OCR Screenshot Interview"].waitForExistence(timeout: 2))
    }

    func testCancellingFromReviewStateLeavesNoEvent() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ocrReviewingState").firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addEventButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fake OCR Screenshot Interview"].waitForExistence(timeout: 2))
    }

    // MARK: 11/12. Continuing into parsing/confirmation + confirming the final event

    func testContinuingIntoParsingPresentsThePrefilledConfirmationForm() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.buttons["ocrContinueButton"].waitForExistence(timeout: 5))
        app.buttons["ocrContinueButton"].tap()

        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, "Fake OCR Screenshot Interview")
    }

    func testConfirmingTheFinalEventCreatesIt() {
        launch()
        openOCRFlow()
        chooseFixtureImage()
        XCTAssertTrue(app.buttons["ocrContinueButton"].waitForExistence(timeout: 5))
        app.buttons["ocrContinueButton"].tap()

        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts["Fake OCR Screenshot Interview"].waitForExistence(timeout: 5))
    }
}
