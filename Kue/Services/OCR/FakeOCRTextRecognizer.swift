//
//  FakeOCRTextRecognizer.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. Deterministic `OCRTextRecognizing` conformer —
//  never touches `Vision`, so it's safe both from `KueTests` (requirement 44, `@testable
//  import Kue`) and, launch-configured via `uiTestLaunchArgument`, from inside the real app
//  process driven by `KueUITests` (requirement 48: never real, uncontrolled Vision recognition
//  in a UI test). Lives in the main target (not KueTests) for the same reason
//  `FakeCalendarProvider` does — `KueApp` needs to be able to install it.
//

import Foundation
import CoreGraphics

@MainActor
final class FakeOCRTextRecognizer: OCRTextRecognizing {
    /// Set via `XCUIApplication.launchArguments` by `KueUITests` cases that exercise the OCR
    /// flow, and only there.
    static let uiTestLaunchArgument = "-uiTestFakeOCR"
    static let uiTestLowConfidenceArgument = "-uiTestFakeOCRLowConfidence"
    static let uiTestNoTextArgument = "-uiTestFakeOCRNoText"
    static let uiTestFailureArgument = "-uiTestFakeOCRFailure"
    static let uiTestUnavailableArgument = "-uiTestFakeOCRUnavailable"

    var availableToReturn: Bool
    var resultToReturn: Result<OCRRecognitionResult, Error>
    /// Only ever non-zero for UI-test-launched instances (`makeFromLaunchArguments`) — long
    /// enough that `OCRImportView`'s loading state is reliably on-screen for a `KueUITests`
    /// case to assert against (requirement 47's "loading state"), never present for unit tests,
    /// which always construct this type directly via the initializer's own zero default.
    var artificialDelayNanoseconds: UInt64
    private(set) var recognizeCallCount = 0

    init(
        availableToReturn: Bool = true,
        resultToReturn: Result<OCRRecognitionResult, Error> = .success(.fixtureEvent),
        artificialDelayNanoseconds: UInt64 = 0
    ) {
        self.availableToReturn = availableToReturn
        self.resultToReturn = resultToReturn
        self.artificialDelayNanoseconds = artificialDelayNanoseconds
    }

    func isAvailable() -> Bool { availableToReturn }

    func recognizeText(in image: CGImage) async throws -> OCRRecognitionResult {
        recognizeCallCount += 1
        if artificialDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        }
        return try resultToReturn.get()
    }

    // MARK: - Launch-argument selection (requirement 42/48)

    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeOCRTextRecognizer? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        // Long enough that `OCRImportView`'s loading state is reliably observable by a
        // `KueUITests` case's own existence-check polling (empirically, a much shorter delay —
        // 0.3s — resolved before the *first* poll ever ran, given XCUITest's own per-step
        // overhead), short enough not to meaningfully slow any other test down.
        let uiTestDelay: UInt64 = 1_500_000_000
        if arguments.contains(uiTestUnavailableArgument) {
            return FakeOCRTextRecognizer(availableToReturn: false)
        }
        if arguments.contains(uiTestNoTextArgument) {
            return FakeOCRTextRecognizer(resultToReturn: .failure(OCRRecognitionError.noTextFound), artificialDelayNanoseconds: uiTestDelay)
        }
        if arguments.contains(uiTestFailureArgument) {
            return FakeOCRTextRecognizer(resultToReturn: .failure(OCRRecognitionError.recognitionFailed("simulated failure")), artificialDelayNanoseconds: uiTestDelay)
        }
        if arguments.contains(uiTestLowConfidenceArgument) {
            return FakeOCRTextRecognizer(resultToReturn: .success(.fixtureLowConfidence), artificialDelayNanoseconds: uiTestDelay)
        }
        return FakeOCRTextRecognizer(resultToReturn: .success(.fixtureEvent), artificialDelayNanoseconds: uiTestDelay)
    }
}

extension OCRRecognitionResult {
    /// `nonisolated` — referenced as a default parameter value above, which Swift evaluates in
    /// a nonisolated context regardless of the surrounding type's own actor (the same
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` quirk `AGENTS.md`'s "concurrency quirk"
    /// section documents for `SystemNotificationScheduler.shared`).
    ///
    /// A clear, deterministic "event screenshot" fixture — used as the default UI-test result
    /// and by unit tests that need a realistic, high-confidence recognized draft.
    nonisolated static let fixtureEvent = OCRRecognitionResult(
        fullText: "Fake OCR Screenshot Interview\nFriday at 10:00 AM\n123 Fake Conference Room",
        lines: [
            OCRTextLine(text: "Fake OCR Screenshot Interview", confidence: 0.95),
            OCRTextLine(text: "Friday at 10:00 AM", confidence: 0.93),
            OCRTextLine(text: "123 Fake Conference Room", confidence: 0.9),
        ],
        confidence: .high
    )

    nonisolated static let fixtureLowConfidence = OCRRecognitionResult(
        fullText: "Fake OCR Low Confidence Text",
        lines: [OCRTextLine(text: "Fake OCR Low Confidence Text", confidence: 0.2)],
        confidence: .low
    )
}
