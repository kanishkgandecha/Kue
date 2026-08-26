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
    case taskDue(taskID: UUID)

    /// e.g. "preparation", "tomorrow", "today", "task-<taskID>" — matches docs/08's own
    /// examples (`"<uuid>-tomorrow"`, `"<uuid>-task-<taskID>"`) exactly.
    var identifierSuffix: String {
        switch self {
        case .preparationStart: return "preparation"
        case .tomorrow: return "tomorrow"
        case .today: return "today"
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
    /// preparation start > per-task task due." Lower sorts first (higher priority).
    var priorityTier: Int {
        switch kind {
        case .today: return 0
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

        let interval = max(fireDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}
