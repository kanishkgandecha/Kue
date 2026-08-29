//
//  SkipEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.7/K." — reuses `EventActions.skip`
//  verbatim (recurring occurrences only — mirrors Event Detail's own "Skip is a recurrence-
//  only action" rule; docs/17-recurring-events.md). Requires confirmation: skipping marks a
//  structural recurrence exception, not just a status flip.
//

import AppIntents
import SwiftData
import Foundation

struct SkipEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Event in Kue"
    static var description = IntentDescription("Skips a single occurrence of a recurring event in Kue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Skip \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        guard event.seriesID != nil else {
            throw KueIntentError.invalidInput(message: "\"\(event.title)\" isn't part of a recurring series, so there's nothing to skip.")
        }
        try await requestConfirmation(dialog: "Skip this occurrence of \"\(event.title)\" in Kue?")
        EventActions.skip(event, context: context)
        return .result(dialog: "Skipped \"\(event.title)\" in Kue.")
    }
}
