//
//  NLParsing.swift
//  Kue
//
//  See docs/06-ai-layer.md "Parser runtime & credentials" (on-device only, no cloud, no
//  telemetry) and "Prompt versioning". Dependency-injection seam (requirement 10) — tests
//  inject a fixture-backed fake conforming to `NLParsing` and never construct a
//  `LanguageModelSession`.
//

import Foundation
import FoundationModels

/// See docs/13-error-handling.md — exact required copy for each failure.
enum ParseFailure: Error, Equatable {
    /// Malformed/missing-field generation output (docs/06-ai-layer.md "schema check").
    case schemaInvalid
    /// The model call itself couldn't run (session error, or availability changed mid-session).
    case modelUnavailable

    var message: String {
        switch self {
        case .schemaInvalid:
            return "Couldn't quite parse that — try rephrasing, or fill it in manually"
        case .modelUnavailable:
            return "On-device AI isn't available right now — add this manually instead"
        }
    }
}

/// Bump whenever `FoundationModelsParser.instructions` changes, and re-run the full fixture
/// set in NLParsingTests before shipping — docs/06-ai-layer.md "Prompt versioning".
let nlParserPromptVersion = "v1"

@MainActor
protocol NLParsing {
    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure>
}

@available(iOS 26.0, *)
@MainActor
final class FoundationModelsParser: NLParsing {
    /// Tagged by `nlParserPromptVersion` — see docs/06-ai-layer.md "Prompt versioning".
    private static let instructions = """
    You extract structured event details from a short piece of natural-language text that \
    describes something the user wants to schedule, e.g. "Interview Friday at 10" or \
    "Trip to Boston next Friday until Sunday". Pull out the title, event type, and any \
    date/time, location, or prep-task language exactly as written.

    Never resolve relative date language ("next Friday," "tomorrow," "in two weeks," "the \
    20th") into an absolute date yourself — copy that language verbatim into rawDateText \
    (and rawEndDateText for an end date/duration) and leave startDate/endDate unset. Only \
    fill in startDate/endDate directly when the input already states a fully absolute date.

    If the event type, date, or anything else needed to create the event is unclear, add an \
    entry to ambiguities with a short, specific question instead of guessing.
    """

    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: text, generating: AIParsedEventDraft.self)
            return .success(response.content)
        } catch {
            return .failure(.schemaInvalid)
        }
    }
}
