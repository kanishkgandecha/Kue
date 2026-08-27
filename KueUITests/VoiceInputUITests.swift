//
//  VoiceInputUITests.swift
//  KueUITests
//
//  Kue 2.0 Phase 6 — On-Device Voice Input, requirement 62: opening Voice input, contextual
//  microphone/speech permission education, privacy disclosure, denied/restricted states,
//  on-device-unavailable, starting recording, live partial transcription, visible recording
//  state and duration, stopping and finalizing, editing transcription, silence, interruption,
//  retry, cancelling, continuing through parsing, confirming the final event.
//
//  Every case launches with `UITestLaunchConfiguration.isolatedStoreArgument` plus
//  `fakeVoiceArgument` (and, where a specific test needs it, one of the state/fixture override
//  arguments) — `KueApp` installs the fake authorization/audio-session/microphone-capture/
//  speech-recognizer quartet (plus `FakeNLParser`/`FakeAIAvailabilityChecker`) whenever that's
//  present, so nothing here ever activates the simulator's or owner's real microphone
//  (requirement 63).
//

import XCTest

final class VoiceInputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
    }

    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeVoiceArgument] + extraArguments
        app.launch()
    }

    private func openVoiceInput() {
        // Import from Calendar / Scan Screenshot / Voice Input are collapsed into one "More
        // Ways to Add" menu — see HomeView's own comment.
        app.buttons["moreAddOptionsButton"].tap()
        app.buttons["voiceInputButton"].tap()
    }

    // MARK: 1. Opening Voice input

    func testOpeningVoiceInputShowsInitialState() {
        launch()
        openVoiceInput()
        XCTAssertTrue(app.buttons["voiceStartRecordingButton"].waitForExistence(timeout: 5))
    }

    // MARK: 2/3. Contextual permission education + privacy disclosure

    func testPrivacyDisclosureIsShownBeforeRecording() {
        launch()
        openVoiceInput()
        // Matched by accessibility identifier, not the full literal string — XCUITest's own
        // identifier-query predicate rejects strings over 128 characters, and this disclosure
        // (deliberately specific, per requirement 37) is longer than that.
        let disclosure = app.descendants(matching: .any).matching(identifier: "voiceOnDeviceDisclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        // The disclosure (requirement 11's contextual education) is on-screen *before* the one
        // deliberate action that requests permission.
        XCTAssertTrue(app.buttons["voiceStartRecordingButton"].exists)
    }

    // MARK: 4. Denied and restricted states

    func testMicrophoneDeniedShowsSettingsLink() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceMicrophoneDeniedArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceOpenSettingsButton"].waitForExistence(timeout: 5))
    }

    func testSpeechRestrictedShowsRetryNotSettings() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceSpeechRestrictedArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceRetryButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["voiceOpenSettingsButton"].exists)
    }

    // MARK: 5. On-device recognition unavailable

    func testOnDeviceRecognitionUnsupportedOffersManualAndOCR() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceOnDeviceUnsupportedArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceSwitchToManualButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceSwitchToOCRButton"].exists)
        XCTAssertTrue(app.buttons["voiceRetryButton"].exists)
    }

    // MARK: 6/7/8. Starting recording, live partial transcription, visible state + duration

    func testStartingRecordingShowsRecordingStateAndDuration() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceRecordingIndicator").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceDurationLabel").firstMatch.waitForExistence(timeout: 5))
    }

    func testLivePartialTranscriptAppearsWhileRecording() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        // The fake recognizer's fixture sequence delivers partials before its final result —
        // this checks the live transcript surface picks at least one of them up before
        // finalizing.
        XCTAssertTrue(app.staticTexts["Fake Voice"].waitForExistence(timeout: 5) || app.staticTexts["Fake Voice Interview"].waitForExistence(timeout: 5))
    }

    // MARK: 9. Stopping and finalizing

    func testStoppingFinalizesIntoReviewingState() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceStopButton"].waitForExistence(timeout: 5))
        app.buttons["voiceStopButton"].tap()
        let editor = app.textViews["voiceTranscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
    }

    // MARK: 10. Editing transcription

    func testEditingTranscription() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        app.buttons["voiceStopButton"].tap()
        let editor = app.textViews["voiceTranscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Edited")
        XCTAssertTrue((editor.value as? String)?.contains("Edited") ?? false)
    }

    // MARK: 11. Silence

    func testSilenceAutoStopsRecording() {
        // Deliberately never delivers anything — real wall-clock wait for
        // `VoiceLimits.silenceTimeout` (5s) to fire via the view's own real ticking loop.
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceNoSpeechArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceStopButton"].waitForExistence(timeout: 5))
        // No-speech fixture also has a short auto-deliver delay (1.5s) which fires a
        // `.noSpeechDetected` *recognition* failure before the 5s silence timeout would even
        // have a chance to — proving the no-speech recovery path lands on its own dedicated
        // state either way.
        XCTAssertTrue(app.staticTexts["No speech was detected. Try again, or add this event manually."].waitForExistence(timeout: 8))
    }

    // MARK: 12. Interruption

    func testInterruptionStopsRecordingGracefully() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceInterruptionArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceStopButton"].waitForExistence(timeout: 5))
        // The fake session manager fires a simulated interruption ~1.5s after activation.
        let editor = app.textViews["voiceTranscriptEditor"]
        let noSpeech = app.staticTexts["No speech was detected. Try again, or add this event manually."]
        XCTAssertTrue(editor.waitForExistence(timeout: 6) || noSpeech.waitForExistence(timeout: 6))
    }

    // MARK: 13. Retry

    func testRetryAfterOnDeviceUnsupportedReturnsToInitialState() {
        launch(extraArguments: [UITestLaunchConfiguration.fakeVoiceOnDeviceUnsupportedArgument])
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceRetryButton"].waitForExistence(timeout: 5))
        app.buttons["voiceRetryButton"].tap()
        XCTAssertTrue(app.buttons["voiceStartRecordingButton"].waitForExistence(timeout: 5))
    }

    // MARK: 14. Cancelling

    func testCancellingFromInitialStateLeavesNoEvent() {
        launch()
        openVoiceInput()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addEventButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fake Voice Interview Friday at 10 AM"].waitForExistence(timeout: 2))
    }

    func testCancellingWhileRecordingLeavesNoEvent() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        XCTAssertTrue(app.buttons["voiceStopButton"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addEventButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fake Voice Interview Friday at 10 AM"].waitForExistence(timeout: 2))
    }

    // MARK: 15/16. Continuing through parsing + confirming the final event

    func testContinuingIntoParsingPresentsThePrefilledConfirmationForm() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        app.buttons["voiceStopButton"].tap()
        XCTAssertTrue(app.buttons["voiceContinueButton"].waitForExistence(timeout: 5))
        app.buttons["voiceContinueButton"].tap()

        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, "Fake OCR Screenshot Interview")
    }

    func testConfirmingTheFinalEventCreatesIt() {
        launch()
        openVoiceInput()
        app.buttons["voiceStartRecordingButton"].tap()
        app.buttons["voiceStopButton"].tap()
        XCTAssertTrue(app.buttons["voiceContinueButton"].waitForExistence(timeout: 5))
        app.buttons["voiceContinueButton"].tap()

        let titleField = app.textFields["eventTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        app.buttons["saveEventButton"].tap()

        XCTAssertTrue(app.staticTexts["Fake OCR Screenshot Interview"].waitForExistence(timeout: 5))
    }
}
