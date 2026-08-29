//
//  CompleteNextTaskControlIntent.swift
//  KueWidget
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "H." — a fully silent control
//  (`openAppWhenRun = false`, the framework default): reuses `EventResolutionService
//  .nextEvent` (Shared/ — the exact same "Next Up" policy Home/the widget use, never
//  re-derived) to find the target event, then `WidgetIntentActions.completeTask` (Shared/ —
//  the same function the widget's own `CompleteTaskIntent` and Siri's
//  `CompleteNextTaskIntent` call) to complete its soonest remaining task. No duplicated
//  mutation logic anywhere in this file.
//

import AppIntents
import SwiftData
import Foundation

struct CompleteNextTaskControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Next Task"
    static var description = IntentDescription("Marks your next event's soonest preparation task complete.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = await ModelContainerFactory.makeDefaultOrNil() else {
            throw WidgetIntentError.storeUnavailable
        }
        let context = ModelContext(container)
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        guard let event = await EventResolutionService.nextEvent(in: allEvents),
              let task = event.tasks.filter({ !$0.isCompleted }).min(by: { $0.dueDate < $1.dueDate }) else {
            return .result(dialog: "No upcoming task to complete in Kue.")
        }

        let result = try await WidgetIntentActions.completeTask(
            taskID: task.id, context: context,
            scheduler: SystemNotificationScheduler.shared, widgetReloader: SystemWidgetReloader.shared
        )
        return .result(dialog: "Marked \"\(result.taskTitle)\" complete.")
    }
}
