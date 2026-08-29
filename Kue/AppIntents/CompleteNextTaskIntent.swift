//
//  CompleteNextTaskIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.9" — reuses
//  `WidgetIntentActions.completeTask` verbatim, the *same* function the widget's own
//  `CompleteTaskIntent` (KueWidget/) calls — no duplicated task-completion logic. When no
//  event is given, resolves via `EventResolutionService.nextEvent` (docs/24 "D." — the same
//  "Next Up" policy Home/the widget already use, never a re-derived one) and acts on *that*
//  event's soonest remaining task. No confirmation: routine and low-risk, matching how a
//  Reminders/Calendar-style "mark done" Siri action behaves.
//

import AppIntents
import SwiftData
import Foundation

struct CompleteNextTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Next Task in Kue"
    static var description = IntentDescription("Marks the next preparation task complete — for a given event, or your next upcoming one.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", default: nil, optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Complete the next task in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try resolveTargetEvent(context: context)

        guard let task = event.tasks.filter({ !$0.isCompleted }).min(by: { $0.dueDate < $1.dueDate }) else {
            throw KueIntentError.noRemainingTask
        }

        let result = try await WidgetIntentActions.completeTask(
            taskID: task.id, context: context,
            scheduler: SystemNotificationScheduler.shared, widgetReloader: SystemWidgetReloader.shared
        )
        return .result(dialog: "Marked \"\(result.taskTitle)\" complete for \"\(event.title)\" in Kue.")
    }

    @MainActor
    private func resolveTargetEvent(context: ModelContext) throws -> KueEvent {
        let hasExplicitTarget = eventIDString != nil || !(query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasExplicitTarget {
            return try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        }
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        guard let next = EventResolutionService.nextEvent(in: allEvents) else {
            throw KueIntentError.noUpcomingEvent
        }
        return next
    }
}
