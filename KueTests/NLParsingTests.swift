//
//  NLParsingTests.swift
//  KueTests
//
//  Exercises the `NLParsing` seam itself (not just the normalizer downstream of it) — a
//  fixture-backed fake stands in for `FoundationModelsParser`, per requirement 10 ("tests
//  never invoke a live model"). Covers the schema-invalid / model-unavailable failure paths
//  from docs/13-error-handling.md, which `NLDraftNormalizerTests` can't reach since those
//  originate at the parse call itself, before there's any `AIParsedEventDraft` to normalize.
//

import Testing
@testable import Kue

@available(iOS 26.0, *)
@MainActor
private final class FixtureNLParser: NLParsing {
    private let outcome: Result<AIParsedEventDraft, ParseFailure>
    init(_ outcome: Result<AIParsedEventDraft, ParseFailure>) { self.outcome = outcome }
    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> { outcome }
}

@MainActor
struct NLParsingTests {
    @Test func validFixtureParsesSuccessfully() async {
        let fixture = AIParsedEventDraft(
            title: "My exam", eventType: "exam", startDate: nil,
            startDateConfidence: "high", rawDateText: "friday at 9",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let parser = FixtureNLParser(.success(fixture))
        let result = await parser.parse(text: "My exam is Friday at 9")
        guard case .success(let parsed) = result else {
            Issue.record("expected success")
            return
        }
        #expect(parsed.title == "My exam")
        #expect(parsed.eventType == "exam")
    }

    @Test func schemaInvalidFailureCarriesTheExactRequiredMessage() async {
        let parser = FixtureNLParser(.failure(.schemaInvalid))
        let result = await parser.parse(text: "asdkfjhaslkdfj")
        guard case .failure(let failure) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(failure == .schemaInvalid)
        #expect(failure.message == "Couldn't quite parse that — try rephrasing, or fill it in manually")
    }

    @Test func modelUnavailableFailureCarriesTheExactRequiredMessage() async {
        let parser = FixtureNLParser(.failure(.modelUnavailable))
        let result = await parser.parse(text: "anything")
        guard case .failure(let failure) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(failure == .modelUnavailable)
        #expect(failure.message == "On-device AI isn't available right now — add this manually instead")
    }

    /// docs/06-ai-layer.md "Prompt versioning" — every fixture pair above is implicitly tied
    /// to this tag; bump it and re-run this file whenever `FoundationModelsParser`'s
    /// instructions text changes.
    @Test func promptVersionIsTagged() {
        #expect(!nlParserPromptVersion.isEmpty)
    }
}
