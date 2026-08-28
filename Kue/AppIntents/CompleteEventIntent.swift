//
//  CompleteEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.5" — reuses `EventActions.complete`
//  verbatim (the same function Event Detail's "Mark Complete" button calls), so notification
//  cleanup, widget reload, Live Activity reconciliation, and Spotlight reindexing all happen
//  identically regardless of which surface triggered the mutation. No confirmation: marking
//  complete is common, low-risk, and reversible via `RestoreEventIntent` — requirement C.
//

import AppIntents
import SwiftData
import Foundation

struct CompleteEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Event in Kue"
    static var description = IntentDescription("Marks an event complete in Kue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        EventActions.complete(event, context: context)
        return .result(dialog: "Marked \"\(event.title)\" complete in Kue.")
    }
}
