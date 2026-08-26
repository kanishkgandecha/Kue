//
//  CompleteTaskIntent.swift
//  KueWidget
//
//  See docs/07-widget-engine.md "CompleteTaskIntent". Runs inside the widget extension's own
//  process (no `openAppWhenRun` override — the `AppIntent` protocol default is `false`), so
//  it must open the shared App Group store itself rather than assuming the main app is
//  running. All the actual logic lives in `WidgetIntentActions.completeTask` (Shared/) so
//  KueTests can exercise it directly through fakes — see that file's header for why.
//

import AppIntents
import SwiftData
import Foundation

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"
    static var description = IntentDescription("Marks a preparation task complete.")

    /// A raw `String`, not `UUID` — `UUID` doesn't conform to the value types `@Parameter`
    /// supports (confirmed against the AppIntents SDK interface; `KueEventEntity.id` uses
    /// `UUID` only because that's an `AppEntity` id, a different, unrelated requirement).
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

        let result = try await WidgetIntentActions.completeTask(
            taskID: taskID,
            context: context,
            scheduler: SystemNotificationScheduler.shared,
            widgetReloader: SystemWidgetReloader.shared
        )

        return .result(dialog: "Marked \"\(result.taskTitle)\" complete.")
    }
}
