//
//  SnoozeTaskIntent.swift
//  KueWidget
//
//  See docs/07-widget-engine.md "SnoozeTaskIntent". Same widget-extension-process model as
//  CompleteTaskIntent — see that file's header. Logic lives in
//  `WidgetIntentActions.snoozeTask` (Shared/).
//

import AppIntents
import SwiftData
import Foundation

struct SnoozeTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Task"
    static var description = IntentDescription("Pushes a preparation task's due date forward by one day, within what's still possible before the event.")

    @Parameter(title: "Task ID")
    var taskIDString: String

    init() {
        taskIDString = ""
    }

    init(taskID: UUID) {
        self.taskIDString = taskID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let taskID = UUID(uuidString: taskIDString) else {
            throw WidgetIntentError.taskNotFound
        }
        guard let container = await ModelContainerFactory.makeDefaultOrNil() else {
            throw WidgetIntentError.storeUnavailable
        }
        let context = ModelContext(container)

        let result = try await WidgetIntentActions.snoozeTask(
            taskID: taskID,
            context: context,
            scheduler: SystemNotificationScheduler.shared,
            widgetReloader: SystemWidgetReloader.shared
        )

        return .result(dialog: "Snoozed — now due \(result.offsetLabel).")
    }
}
