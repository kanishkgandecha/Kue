//
//  NLParsingPipeline.swift
//  Kue
//
//  See docs/06-ai-layer.md "Pipeline": "raw input → AI interpretation → structured JSON →
//  schema validation → normalization → KueEvent draft." The exact "parse, then normalize"
//  sequence, factored out so every NL entry point calls the *same* orchestration instead of
//  each re-sequencing the same two calls itself — Phase 10 (M9) requirement 4: "do not
//  duplicate parser or validation business logic inside the [Share] extension." Neither this
//  file nor its callers re-implement anything `NLParsing`/`NLDraftNormalizer` already own;
//  this is glue, not a third copy of the logic.
//
//  Lives in Kue/Services/ (not Shared/) — reachable by both the app target and the Share
//  Extension target, which also syncs the `Kue/` folder (see AGENTS.md "Two+ targets").
//

import Foundation

@available(iOS 26.0, *)
enum NLParsingPipeline {
    struct Outcome {
        /// `nil` only on `failureMessage != nil` — a failed parse never produces a draft to
        /// silently half-populate (docs/13-error-handling.md: "Neither case should ever
        /// create a partially-filled KueEvent silently").
        var draft: EventDraft?
        var ambiguities: [DraftAmbiguity]
        var failureMessage: String?
    }

    static func run(
        text: String,
        parser: NLParsing,
        timeZoneIdentifier: String,
        now: Date = .now
    ) async -> Outcome {
        switch await parser.parse(text: text) {
        case .success(let parsed):
            let normalized = NLDraftNormalizer.normalize(parsed, referenceDate: now, timeZoneIdentifier: timeZoneIdentifier)
            return Outcome(draft: normalized.draft, ambiguities: normalized.ambiguities, failureMessage: nil)
        case .failure(let failure):
            return Outcome(draft: nil, ambiguities: [], failureMessage: failure.message)
        }
    }
}
