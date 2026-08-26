//
//  NLParsingPipelineTests.swift
//  KueTests
//
//  See docs/06-ai-layer.md "Pipeline" and Phase 10 (M9) requirement 4: "do not duplicate
//  parser or validation business logic." This is the exact orchestration both
//  `EventFormView`'s typed NL input and the Share Extension call — tested once, here, rather
//  than separately per call site. Requirement 9 (Share Extension tests): "parser failure,"
//  "ambiguity" — both originate here, upstream of anything Share-Extension-specific.
//

import Testing
import Foundation
@testable import Kue

@available(iOS 26.0, *)
@MainActor
private final class FixtureNLParser: NLParsing {
    private let outcome: Result<AIParsedEventDraft, ParseFailure>
    init(_ outcome: Result<AIParsedEventDraft, ParseFailure>) { self.outcome = outcome }
    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> { outcome }
}

@MainActor
struct NLParsingPipelineTests {
    @Test func successfulParseProducesADraftWithNoFailureMessage() async {
        let fixture = AIParsedEventDraft(
            title: "Interview", eventType: "interview", startDate: nil,
            startDateConfidence: "low", rawDateText: "friday at 10",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: "Interview Friday at 10",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft?.title == "Interview")
        #expect(outcome.draft?.eventType == .interview)
        #expect(outcome.failureMessage == nil)
    }

    // MARK: - Ambiguity (requirement 9: "ambiguity")

    @Test func modelFlaggedAmbiguityCarriesThroughToTheOutcome() async {
        let fixture = AIParsedEventDraft(
            title: "Team meeting", eventType: nil, startDate: nil,
            startDateConfidence: "low", rawDateText: "next friday",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [],
            ambiguities: [AIAmbiguity(field: "eventType", question: "Is this an interview or a generic meeting?")]
        )
        let outcome = await NLParsingPipeline.run(
            text: "Team meeting next friday",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft != nil)
        #expect(outcome.ambiguities.contains { $0.field == "eventType" })
    }

    @Test func unresolvableDateProducesAStartDateAmbiguity() async {
        let fixture = AIParsedEventDraft(
            title: "Something", eventType: "generic", startDate: nil,
            startDateConfidence: "low", rawDateText: "sometime soonish",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: "Something sometime soonish",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.ambiguities.contains { $0.field == "startDate" })
    }

    // MARK: - Parser failure (requirement 9: "parser failure")

    @Test func schemaInvalidFailureProducesNoDraftAndTheExactMessage() async {
        let outcome = await NLParsingPipeline.run(
            text: "asdkfj",
            parser: FixtureNLParser(.failure(.schemaInvalid)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft == nil)
        #expect(outcome.ambiguities.isEmpty)
        #expect(outcome.failureMessage == "Couldn't quite parse that — try rephrasing, or fill it in manually")
    }

    @Test func modelUnavailableFailureProducesNoDraftAndTheExactMessage() async {
        let outcome = await NLParsingPipeline.run(
            text: "anything",
            parser: FixtureNLParser(.failure(.modelUnavailable)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft == nil)
        #expect(outcome.failureMessage == "On-device AI isn't available right now — add this manually instead")
    }

    // MARK: - Duplicate sharing (requirement 9) — the pipeline's draft is what
    // `DuplicateDetectionService` (already Phase 2-tested) checks against; this proves a
    // share-originated draft carries the same title/date shape a duplicate check depends on.

    @Test func aShareOriginatedDraftIsDetectableAsADuplicateOfAnExistingEvent() async throws {
        let existing = KueEvent(
            title: "Salesforce Interview", eventType: .interview,
            startDate: Date(timeIntervalSince1970: 2_000_000), estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC", source: .manual
        )
        let fixture = AIParsedEventDraft(
            title: "Salesforce Interview", eventType: "interview",
            startDate: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 2_000_000)),
            startDateConfidence: "high", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: "Salesforce Interview", parser: FixtureNLParser(.success(fixture)), timeZoneIdentifier: "UTC"
        )
        let draft = try #require(outcome.draft)
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: draft.title, startDate: draft.startDate, timeZoneIdentifier: draft.timeZoneIdentifier, in: [existing]
        )
        #expect(duplicate === existing)
    }
}
