//
//  AIParsedEventDraft.swift
//  Kue
//
//  See docs/06-ai-layer.md "Parser contract (V1)" — the exact output JSON schema, expressed
//  as `@Generable` types so Foundation Models' guided generation enforces it directly (a
//  malformed/missing field is therefore a generation failure, not something this layer has
//  to hand-validate — see NLDraftNormalizer for the deterministic checks that still apply
//  to values the schema *can't* constrain, e.g. date-range sanity).
//
//  `startDate`/`endDate` exist only for the rare case the model resolves an absolute date on
//  its own authority; `rawDateText`/`rawEndDateText` are what Kue's own deterministic
//  resolver (RelativeDateResolver) actually trusts — see NLDraftNormalizer.
//

import FoundationModels

@available(iOS 26.0, *)
@Generable
struct AIParsedEventDraft {
    @Guide(description: "The event's title, extracted verbatim from the input text.")
    var title: String

    @Guide(description: "One of: generic, deadline, exam, interview, trip. Omit if the type is unclear — defer to the user rather than guessing.")
    var eventType: String?

    @Guide(description: "An absolute ISO-8601 date/time, filled in ONLY when the input already states an absolute date with no relative language to resolve (rare). Leave unset for anything relative like 'next Friday' or 'tomorrow' — use rawDateText for those instead.")
    var startDate: String?

    @Guide(description: "Either 'high' or 'low' — how confident the date/time extraction is.")
    var startDateConfidence: String

    @Guide(description: "The verbatim date/time language from the input, e.g. 'next Friday at 10', 'the 20th'. This is what actually gets resolved into a real date — never resolve it yourself.")
    var rawDateText: String?

    @Guide(description: "An absolute ISO-8601 end date, filled in ONLY when already stated absolutely in the input (rare). Leave unset otherwise — use rawEndDateText.")
    var endDate: String?

    @Guide(description: "Verbatim end-date/duration language for trip-style events, e.g. 'until Sunday', 'for 5 days'.")
    var rawEndDateText: String?

    @Guide(description: "A location mentioned in the input, if any.")
    var location: String?

    @Guide(description: "Any additional free-text detail that isn't the title, date, or location.")
    var notes: String?

    @Guide(description: "Prep tasks the input explicitly asks for, e.g. 'remind me to pack two days before'. Empty if none.")
    var prepRequests: [AIPrepRequest]

    @Guide(description: "Anything unclear enough that Kue should ask the user instead of guessing. Empty if nothing is ambiguous.")
    var ambiguities: [AIAmbiguity]
}

@available(iOS 26.0, *)
@Generable
struct AIPrepRequest {
    @Guide(description: "What the prep task is, e.g. 'pack bags'.")
    var description: String

    @Guide(description: "Natural-language timing relative to the event, e.g. 'two days before'.")
    var offsetHint: String
}

@available(iOS 26.0, *)
@Generable
struct AIAmbiguity {
    @Guide(description: "Which field is unclear, e.g. 'startDate', 'endDate', 'eventType'.")
    var field: String

    @Guide(description: "A short, specific clarifying question for the user, e.g. 'Do you mean September 4th?'")
    var question: String
}
