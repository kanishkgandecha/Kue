//
//  CreateEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.1" — a structured, deterministic
//  create (title/type/date/all-day, no NL parsing involved). Persists through
//  `EventCreationService` (Kue/Services/, shared with `EventFormView.save()` and
//  `QuickAddEventIntent`) — no duplicated mutation logic. Runs silently (`openAppWhenRun =
//  false`): creating is additive and easily undone (delete/edit in the app), so this doesn't
//  need confirmation or to open the app — requirement: "opening/finding/showing data should
//  not require unnecessary confirmation" extends the same way to a low-risk, reversible create.
//

import AppIntents
import SwiftData
import Foundation

struct CreateEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Event"
    static var description = IntentDescription("Creates a new event in Kue with the details you give it.")

    @Parameter(title: "Title")
    var eventTitle: String

    @Parameter(title: "Event Type", default: .generic)
    var eventType: EventTypeOption

    @Parameter(title: "Date", kind: .dateTime)
    var startDate: Date

    @Parameter(title: "All Day", default: false)
    var isAllDay: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$eventTitle) in Kue on \(\.$startDate)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var draft = EventDraft(eventType: eventType.eventType)
        draft.title = eventTitle
        draft.startDate = startDate
        draft.isAllDay = isAllDay

        let errors = EventValidator.validate(draft)
        guard errors.isEmpty else {
            throw KueIntentError.invalidInput(message: errors.first?.errorDescription ?? "That event's details aren't valid.")
        }

        let context = try KueIntentSupport.makeContext()
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context)
        await EventCreationService.reconcileAfterWrite(event, context: context)

        return .result(dialog: "Created \"\(event.title)\" in Kue.")
    }
}
