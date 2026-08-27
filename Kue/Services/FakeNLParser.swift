//
//  FakeNLParser.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. `EventFormView`'s NL entry point and
//  `OCRImportView`'s "Continue" step both read `\.nlParser`/`\.aiAvailabilityChecker`
//  (AIEnvironment.swift), which `KueApp` installs as the real, on-device Apple-Intelligence-
//  backed implementations unconditionally — Apple Intelligence is not available in the iOS
//  Simulator at all, so a `KueUITests` case that needs to drive recognized OCR text all the way
//  through parsing (requirement 47: "continuing into the existing parsing/confirmation flow,"
//  "confirming the final event") needs a deterministic stand-in, the same "launch-argument-
//  gated fake" shape `FakeCalendarProvider`/`FakeOCRTextRecognizer` already establish. Installed
//  by `KueApp` only alongside `FakeOCRTextRecognizer.uiTestLaunchArgument` — every OCR UI test
//  that needs to reach "Continue" already passes that argument, so no separate one is needed
//  here.
//

import Foundation

@available(iOS 26.0, *)
@MainActor
final class FakeNLParser: NLParsing {
    var outcomeToReturn: Result<AIParsedEventDraft, ParseFailure>

    init(outcomeToReturn: Result<AIParsedEventDraft, ParseFailure> = .success(.fixtureOCRInterview)) {
        self.outcomeToReturn = outcomeToReturn
    }

    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> {
        outcomeToReturn
    }
}

@MainActor
final class FakeAIAvailabilityChecker: AIAvailabilityChecking {
    var stateToReturn: AIAvailabilityState

    init(stateToReturn: AIAvailabilityState = .available) {
        self.stateToReturn = stateToReturn
    }

    func currentAvailability() -> AIAvailabilityState { stateToReturn }
}

@available(iOS 26.0, *)
extension AIParsedEventDraft {
    /// A deterministic stand-in for what a real parse of `OCRRecognitionResult.fixtureEvent`'s
    /// text would plausibly produce. Uses an absolute ISO-8601 `startDate` rather than a
    /// `rawDateText` phrase deliberately — `NLDraftNormalizer` only falls back to parsing
    /// `startDate` directly when `rawDateText` is empty, so this sidesteps
    /// `RelativeDateResolver`'s own phrase-matching (already covered by its own test suite)
    /// and keeps this fixture's resulting draft date fixed and ambiguity-free regardless of
    /// when a UI test actually runs.
    nonisolated static let fixtureOCRInterview = AIParsedEventDraft(
        title: "Fake OCR Screenshot Interview",
        eventType: "interview",
        startDate: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)),
        startDateConfidence: "high",
        rawDateText: nil,
        endDate: nil,
        rawEndDateText: nil,
        location: "123 Fake Conference Room",
        notes: nil,
        prepRequests: [],
        ambiguities: []
    )
}
