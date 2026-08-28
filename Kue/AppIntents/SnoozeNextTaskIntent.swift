//
//  SnoozeNextTaskIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.10" — reuses
//  `WidgetIntentActions.snoozeTask` verbatim, the same function the widget's own
//  `SnoozeTaskIntent` (KueWidget/) calls. No confirmation: routine and reversible (the task
//  just moves forward a day, same as tapping the widget's snooze button).
//

import AppIntents
import SwiftData
import Foundation

struct SnoozeNextTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Next Task in Kue"
    static var description = IntentDescription("Pushes the next preparation task's due date forward by a day — for a given event, or your next upcoming one.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", default: nil, optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze the next task in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let hasExplicitTarget = eventIDString != nil || !(query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let event: KueEvent
        if hasExplicitTarget {
            event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        } else {
            let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
            guard let next = EventResolutionService.nextEvent(in: allEvents) else { throw KueIntentError.noUpcomingEvent }
            event = next
        }

        guard let task = event.tasks.filter({ !$0.isCompleted }).min(by: { $0.dueDate < $1.dueDate }) else {
            throw KueIntentError.noRemainingTask
        }

        do {
            let result = try await WidgetIntentActions.snoozeTask(
                taskID: task.id, context: context,
                scheduler: SystemNotificationScheduler.shared, widgetReloader: SystemWidgetReloader.shared
            )
            return .result(dialog: "Snoozed — \"\(task.title)\" is now due \(result.offsetLabel).")
        } catch WidgetIntentError.noSnoozeIntervalRemains {
            throw KueIntentError.noSnoozeIntervalRemains
        }
    }
}
