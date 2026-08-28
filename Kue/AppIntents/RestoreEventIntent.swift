//
//  RestoreEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.8" — a single coherent "undo
//  whichever terminal/inactive state currently applies" action rather than four near-duplicate
//  intents (Un-cancel/Un-skip/Unarchive/Mark Not Complete each already exist as distinct
//  `EventActions` functions and distinct Event Detail buttons — this intent picks the right
//  one for you, the same way a person asking "restore this event" doesn't know or care which
//  internal flag is set). No confirmation: restoring is corrective, not destructive.
//
//  Precedence mirrors `EventStatusEngine.derive`'s own documented precedence (archived is
//  checked independently of derive, then cancelled before skipped before manual completion).
//

import AppIntents
import SwiftData
import Foundation

struct RestoreEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore Event in Kue"
    static var description = IntentDescription("Undoes whichever cancelled, skipped, completed, or archived state currently applies to an event in Kue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Restore \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)

        if event.status == .archived {
            await EventActions.unarchive(event, context: context)
            return .result(dialog: "Unarchived \"\(event.title)\" in Kue.")
        } else if event.isCancelled {
            await EventActions.uncancel(event, context: context)
            return .result(dialog: "Un-cancelled \"\(event.title)\" in Kue.")
        } else if event.isSkipped {
            await EventActions.unskip(event, context: context)
            return .result(dialog: "Un-skipped \"\(event.title)\" in Kue.")
        } else if event.isManuallyCompleted {
            await EventActions.uncomplete(event, context: context)
            return .result(dialog: "Marked \"\(event.title)\" not complete in Kue.")
        }

        return .result(dialog: "\"\(event.title)\" isn't cancelled, skipped, completed, or archived — nothing to restore.")
    }
}
