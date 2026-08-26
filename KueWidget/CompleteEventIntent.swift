//
//  CompleteEventIntent.swift
//  KueWidget
//
//  See docs/07-widget-engine.md "CompleteEventIntent". Same widget-extension-process model
//  as CompleteTaskIntent — see that file's header. Also reachable from Event Detail in the
//  main app via `EventActions.complete` (Kue/, unchanged from Phase 8) — docs/07: "a user
//  shouldn't be able to mark an event complete from the widget but not from the app itself."
//  Logic here is `WidgetIntentActions.completeEvent` (Shared/); see that file's header for
//  why it isn't literally the same function `EventActions.complete` calls.
//

import AppIntents
import SwiftData
import Foundation

struct CompleteEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Event Complete"
    static var description = IntentDescription("Marks the whole event complete, independent of its date.")

    @Parameter(title: "Event ID")
    var eventIDString: String

    init() {
        eventIDString = ""
    }

    init(eventID: UUID) {
        self.eventIDString = eventID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let eventID = UUID(uuidString: eventIDString) else {
            throw WidgetIntentError.eventNotFound
        }
        guard let container = await ModelContainerFactory.makeDefaultOrNil() else {
            throw WidgetIntentError.storeUnavailable
        }
        let context = ModelContext(container)

        let result = try await WidgetIntentActions.completeEvent(
            eventID: eventID,
            context: context,
            scheduler: SystemNotificationScheduler.shared,
            widgetReloader: SystemWidgetReloader.shared
        )

        return .result(dialog: "Marked \"\(result.eventTitle)\" complete.")
    }
}
