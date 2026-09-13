//
//  CancelEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.6/K." — reuses `EventActions.cancel`
//  verbatim. Requires confirmation: cancelling is a more consequential state change than
//  completing (it clears any prior manual completion too, and for a recurring occurrence marks
//  a recurrence exception) — requirement C: "request confirmation where the consequence is
//  surprising or destructive."
//

import AppIntents
import SwiftData
import Foundation

struct CancelEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Event in Kue"
    static var description = IntentDescription("Cancels an event in Kue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        try await requestConfirmation(dialog: "Cancel \"\(event.title)\" in Kue?")
        // Kue 3.0 Phase 8 correction pass — the awaitable variant, not `cancel`: this intent's
        // hosting process can be suspended the instant `perform()` returns
        // (`openAppWhenRun = false`), so Live Activity/Spotlight reconciliation must actually
        // finish before that happens, not be left running in an orphaned `Task`.
        await EventActions.cancelAwaitingReconciliation(event, context: context)
        return .result(dialog: "Cancelled \"\(event.title)\" in Kue.")
    }
}
