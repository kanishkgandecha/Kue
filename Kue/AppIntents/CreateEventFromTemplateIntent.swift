//
//  CreateEventFromTemplateIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.15" — mirrors what
//  `TemplatesView`'s own row tap does: pre-select an `EventType`, then run through the exact
//  same deterministic `EventCreationService.create` path (which regenerates the type's default
//  preparation schedule via `SchedulingEngine`) — no template-specific creation logic, no
//  `Template` `@Model` row involved (V1 doesn't persist template rows at all; see
//  `TemplatesView.swift`'s own header). Additive and reversible — no confirmation.
//

import AppIntents
import SwiftData
import Foundation

struct CreateEventFromTemplateIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Event from Template in Kue"
    static var description = IntentDescription("Creates a new event in Kue pre-set to one of its built-in templates (Interview, Exam, Trip, Deadline).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Template")
    var template: EventTemplateOption

    @Parameter(title: "Title")
    var eventTitle: String

    @Parameter(title: "Date", kind: .dateTime)
    var startDate: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$eventTitle) from the \(\.$template) template in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var draft = EventDraft(eventType: template.eventType)
        draft.title = eventTitle
        draft.startDate = startDate

        let errors = EventValidator.validate(draft)
        guard errors.isEmpty else {
            throw KueIntentError.invalidInput(message: errors.first?.errorDescription ?? "That event's details aren't valid.")
        }

        let context = try KueIntentSupport.makeContext()
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context)
        await EventCreationService.reconcileAfterWrite(event, context: context)

        return .result(dialog: "Created \"\(event.title)\" from the \(template.eventType.displayName) template in Kue.")
    }
}
