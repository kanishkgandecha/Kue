//
//  QuickAddEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.2/F." — Quick Add's natural-
//  language route. Routes through the *same* `NLParsingPipeline` (Kue/Services/) typed Quick
//  Add and the Share Extension already use — no second parser, no duplicated normalization.
//  `openAppWhenRun = true`: when the parse is ambiguous or fails, this must open Kue's
//  existing confirmation flow with a prefilled draft (requirement F) rather than silently
//  guessing or persisting something unconfirmed — that's only possible with the app in
//  foreground. When the parse is fully deterministic, this still creates directly (no extra
//  tap), and the app simply comes forward already showing the result.
//

import AppIntents
import SwiftData
import Foundation

@available(iOS 26.0, *)
struct QuickAddEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Add Event"
    static var description = IntentDescription("Adds an event to Kue from a short description, like \"Interview Friday at 10\".")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Description")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Quick Add \(\.$text) to Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()

        // docs/03-data-model.md `UserPreference.aiParsingEnabled` — the same silent (no
        // error) manual fallback `ShareExtensionRootView`/`EventFormView` already use for an
        // explicit user opt-out, never treated as an *unavailability* error.
        guard UserPreferenceStore.current(context: context).aiParsingEnabled else {
            KueIntentSupport.openDeepLink(KueDeepLink.url(for: .addFromText(text)))
            return .result(dialog: "AI parsing is off in Kue — opening the form so you can fill it in.")
        }

        let availability = SystemAIAvailabilityChecker().currentAvailability()
        guard availability.isAvailable else {
            throw KueIntentError.parsingUnavailable(message: availability.message ?? "AI text parsing isn't available on this device — add it manually instead.")
        }

        let outcome = await NLParsingPipeline.run(
            text: text, parser: FoundationModelsParser(), timeZoneIdentifier: TimeZone.current.identifier
        )
        guard let draft = outcome.draft else {
            // Parse failed outright — still honor "open Kue's existing confirmation flow with
            // a prefilled draft," using the raw text as the title (same fallback
            // `ShareExtensionRootView.presentFallback` establishes).
            KueIntentSupport.openDeepLink(KueDeepLink.url(for: .addFromText(text)))
            return .result(dialog: IntentDialog(stringLiteral: outcome.failureMessage ?? "Couldn't quite parse that — opening Kue so you can fill it in."))
        }

        guard outcome.ambiguities.isEmpty, EventValidator.validate(draft).isEmpty else {
            // Deliberately re-parses once more in-app (docs/24 "F.": "the raw text travels in
            // the URL, not a pre-parsed draft") rather than trying to serialize `draft`/
            // `ambiguities` across the deep-link boundary.
            KueIntentSupport.openDeepLink(KueDeepLink.url(for: .addFromText(text)))
            return .result(dialog: "That needs a quick confirmation in Kue before I can create it.")
        }

        // Fully deterministic and safe — create directly (requirement F).
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context)
        await EventCreationService.reconcileAfterWrite(event, context: context)
        return .result(dialog: "Added \"\(event.title)\" to Kue.")
    }
}
