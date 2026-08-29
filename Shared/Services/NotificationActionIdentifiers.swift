//
//  NotificationActionIdentifiers.swift
//  Kue
//
//  See docs/25-honest-event-outcomes-and-reminders.md "K." — the notification-category/action
//  identifier constants both `NotificationCandidate.makeRequest()` (Shared/, tags a request
//  with a category) and `Kue/Services/NotificationActionHandler.swift` (app-only, registers
//  the category and routes action responses) must agree on exactly — same "one shared literal"
//  rationale `WidgetKind`/`KueDeepLink` already establish for their own cross-file constants.
//  Plain strings only — no `UNUserNotificationCenter`/`UIKit` dependency — so this can live in
//  `Shared/` without dragging UIKit into the widget extension or Share Extension targets.
//

import Foundation

nonisolated enum NotificationActionIdentifiers {
    /// The one actionable category this phase adds — docs/25 "K.": Mark Completed/Reschedule/
    /// Skip/Cancel, offered on the outcome-follow-up notification specifically (the exact
    /// moment those four choices are most relevant).
    static let outcomeFollowUpCategory = "KUE_OUTCOME_FOLLOW_UP"

    static let completeActionID = "KUE_ACTION_COMPLETE"
    /// `options: [.foreground]` — opens the app to the exact event's Event Detail (docs/25
    /// "K.": "If Reschedule cannot be completed inside the notification action, deep-link to
    /// the exact Event Detail/edit flow rather than pretending it was rescheduled").
    static let rescheduleActionID = "KUE_ACTION_RESCHEDULE"
    static let skipActionID = "KUE_ACTION_SKIP"
    static let cancelActionID = "KUE_ACTION_CANCEL"
}
