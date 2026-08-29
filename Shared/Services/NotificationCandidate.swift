//
//  NotificationCandidate.swift
//  Kue
//
//  See docs/08-notifications.md "Notification categories" / "Deduplication" / "Pending-
//  notification limit". A pure value type — no SwiftData, no live `UNUserNotificationCenter`
//  — so NotificationCandidateBuilder's output is independently testable. Lives in Shared/
//  (not app-only) because Phase 9's widget-extension-executing `SnoozeTaskIntent` needs
//  `makeRequest()` below too, not just the app-target `NotificationEngine`.
//

import Foundation
import UserNotifications

/// The `transitionKind` half of docs/08's identifier format
/// (`"\(event.id)-\(transitionKind)"`). `nonisolated` — otherwise this module's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes its `Equatable` conformance
/// MainActor-isolated too, which Swift Testing's `#expect` can't use from a test body that
/// isn't itself `@MainActor` (same fix `SchedulingEngine.ScheduledTaskPlan` needed).
nonisolated enum NotificationTransitionKind: Equatable, Hashable {
    case preparationStart
    case tomorrow
    case today
    /// Kue 2.0 Phase 10.1 — docs/25 "H." concept 4: the configurable pre-event reminder,
    /// fired `ReminderPreference.preEventMinutes` before `startDate`. No associated value —
    /// exactly one pre-event reminder exists per event at a time, so a fixed identifier means
    /// changing the configured duration naturally replaces the old pending request under the
    /// same identifier rather than needing its own stale-identifier cleanup.
    case preEvent
    /// docs/25 "H." concept 5 — fires at the event's actual `startDate` (or a pinned-timezone
    /// morning time for all-day events), not at midnight.
    case eventStart
    /// docs/25 "H." concept 6 — "How did it go?", fired at `effectiveEndDate`.
    case outcomeFollowUp
    case taskDue(taskID: UUID)

    /// e.g. "preparation", "tomorrow", "today", "task-<taskID>" — matches docs/08's own
    /// examples (`"<uuid>-tomorrow"`, `"<uuid>-task-<taskID>"`) exactly.
    var identifierSuffix: String {
        switch self {
        case .preparationStart: return "preparation"
        case .tomorrow: return "tomorrow"
        case .today: return "today"
        case .preEvent: return "pre-event"
        case .eventStart: return "event-start"
        case .outcomeFollowUp: return "outcome-follow-up"
        case .taskDue(let taskID): return "task-\(taskID.uuidString)"
        }
    }
}

/// One `(event, transitionKind)` slot the notification engine might schedule. `nonisolated`
/// for the same reason as `NotificationTransitionKind` above.
nonisolated struct NotificationCandidate: Equatable {
    var eventID: UUID
    var kind: NotificationTransitionKind
    var fireDate: Date
    /// True when this candidate belongs to docs/08's "Today / urgent" category even though
    /// `kind` is `.tomorrow` — that category's trigger is explicitly "WidgetLifecyclePhase
    /// transitions to today, **or urgent treatment applies**" (docs/07-widget-engine.md's
    /// urgent-treatment rule fires within the `tomorrow`/`today` phases for Interview/
    /// Deadline events). `.today` is always this tier regardless of event type.
    var isUrgentTier: Bool
    var title: String
    var body: String

    /// docs/08-notifications.md "Deduplication" — stable, deterministic identifier.
    var identifier: String { "\(eventID)-\(kind.identifierSuffix)" }

    /// docs/08-notifications.md "Priority-ordered fill": "today/urgent > tomorrow >
    /// preparation start > per-task task due." Lower sorts first (higher priority). Kue 2.0
    /// Phase 10.1 (docs/25 "J.") — event-start, the configured pre-event reminder, and the
    /// outcome follow-up join tier 0: "near-term start reminders must outrank distant
    /// preparation/task reminders" and "outcome follow-up must not be starved by low-priority
    /// distant reminders." All three are also the ones `.minimal` intensity still shows
    /// (`NotificationCandidateBuilder.filter`'s `priorityTier == 0` gate) — deliberately: a
    /// user who wants only the essentials should still get "it's starting" and "how did it
    /// go," not just today's morning summary.
    var priorityTier: Int {
        switch kind {
        case .today, .eventStart, .preEvent, .outcomeFollowUp: return 0
        case .tomorrow: return isUrgentTier ? 0 : 1
        case .preparationStart: return 2
        case .taskDue: return 3
        }
    }

    /// docs/08-notifications.md "Scheduling model": "a calendar or time-interval trigger."
    /// Time-interval is used here — `fireDate` is already an absolute instant resolved
    /// against the event's own pinned timezone upstream (WidgetContentService/
    /// SchedulingEngine), so converting it to "seconds from now" is timezone-agnostic and
    /// avoids re-deriving `DateComponents` in whatever zone the trigger would otherwise use.
    func makeRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Kue 2.0 Phase 10.1 — docs/25 "K.": only the outcome follow-up offers the Mark
        // Completed/Reschedule/Skip/Cancel action set; every other kind keeps its existing
        // plain-tap-to-open behavior.
        if kind == .outcomeFollowUp {
            content.categoryIdentifier = NotificationActionIdentifiers.outcomeFollowUpCategory
        }

        let interval = max(fireDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}
