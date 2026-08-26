//
//  WidgetIntentActions.swift
//  Kue
//
//  See docs/07-widget-engine.md "Interactive widgets — Phase 9 (inside V1, not post-V1)" —
//  the exact contract for `CompleteTaskIntent`/`SnoozeTaskIntent`/`CompleteEventIntent`. The
//  actual `AppIntent` structs live in KueWidget/ (App Intents attached to a widget button run
//  inside the widget extension's own process, not the main app — that's what "without
//  requiring the main app to foreground" means in practice), but the logic below lives here
//  in Shared/ for two reasons: (1) it needs to be reachable from *both* KueWidget (the real
//  call site) and the "Kue" module KueTests imports (`@testable import Kue` only sees
//  Shared/ + Kue/, never KueWidget/ — see AGENTS.md), and (2) none of it actually needs
//  SwiftUI/WidgetKit-specific APIs beyond the injectable `WidgetReloading` seam.
//
//  `EventActions.complete` (Kue/, app-only) already does almost exactly what
//  `completeEvent` below does, for the app's own "Mark Complete" button — the ~6-line
//  mutual-exclusion-and-cleanup logic is intentionally duplicated here rather than moved,
//  since `EventActions` also pulls in `NotificationEngine`'s full cap-aware reschedule engine
//  (app-only, and unneeded here — these three intents only ever *remove* pending requests,
//  per the doc contract, never run the global reschedule pass) and moving the whole file
//  would be a wider, riskier change to already-shipped Phase 8 code than this phase calls for.
//
//  All three follow the same write path docs/07 prescribes: shared `ModelContext` → persist
//  → notification-identifier cleanup → `EventStatusEngine.sweep` (docs/04-event-types.md
//  "Reconciliation": "the sweep runs after every intent uniformly rather than conditionally")
//  → `WidgetCenter` reload.
//

import Foundation
import SwiftData
import UserNotifications

enum WidgetIntentError: Error, LocalizedError, Equatable {
    /// The shared App Group store couldn't be opened at all.
    case storeUnavailable
    /// No `KueTask` with the given id exists (already deleted, or a stale identifier).
    case taskNotFound
    /// The task exists but its parent `KueEvent` relationship is nil — an orphaned row that
    /// should never occur in practice, but a widget button can be tapped on stale rendered
    /// content, so this is handled rather than force-unwrapped.
    case taskEventUnavailable
    /// No `KueEvent` with the given id exists (already deleted, or a stale identifier).
    case eventNotFound
    /// docs/07-widget-engine.md: "If that range is empty ... the snooze button is hidden."
    /// Thrown defensively if `perform()` is ever invoked anyway (e.g. a stale widget entry
    /// whose button predates the event becoming imminent).
    case noSnoozeIntervalRemains

    var errorDescription: String? {
        switch self {
        case .storeUnavailable: return "Kue's shared data isn't available right now."
        case .taskNotFound: return "That task no longer exists."
        case .taskEventUnavailable: return "That task's event is no longer available."
        case .eventNotFound: return "That event no longer exists."
        case .noSnoozeIntervalRemains: return "There's no time left to snooze this task."
        }
    }
}

enum WidgetIntentActions {
    struct TaskCompletionResult: Equatable {
        var taskTitle: String
    }

    /// docs/07-widget-engine.md "CompleteTaskIntent" — marks the task complete, stamps
    /// `completedAt`, removes *only that task's* pending notification, and never touches
    /// `KueEvent.status` (task completion is explicitly not a status input — docs/04
    /// "Status transition rules").
    @discardableResult
    static func completeTask(
        taskID: UUID,
        context: ModelContext,
        scheduler: NotificationScheduling,
        widgetReloader: WidgetReloading,
        now: Date = .now
    ) throws -> TaskCompletionResult {
        guard let task = try? context.fetch(FetchDescriptor<KueTask>(predicate: #Predicate { $0.id == taskID })).first else {
            throw WidgetIntentError.taskNotFound
        }
        guard let event = task.event else {
            throw WidgetIntentError.taskEventUnavailable
        }

        task.isCompleted = true
        task.completedAt = now
        try? context.save()

        let identifier = "\(event.id)-\(NotificationTransitionKind.taskDue(taskID: task.id).identifierSuffix)"
        scheduler.removePendingNotificationRequests(withIdentifiers: [identifier])

        EventStatusEngine.sweep(context: context, now: now)
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)

        return TaskCompletionResult(taskTitle: task.title)
    }

    struct TaskSnoozeResult: Equatable {
        var newDueDate: Date
        var offsetLabel: String
    }

    /// docs/07-widget-engine.md "SnoozeTaskIntent" — clamps to
    /// `[now + minimumLeadTime, event.startDate - minimumLeadTime]`, throws
    /// `.noSnoozeIntervalRemains` when that range is empty, regenerates `offsetLabel` to
    /// match the actual new date, and re-schedules the task's notification under its
    /// existing stable identifier (removing the stale one first) — but only when a task-due
    /// notification would exist at all (`.all` intensity, permission already granted);
    /// otherwise there was never one pending to begin with.
    @discardableResult
    static func snoozeTask(
        taskID: UUID,
        context: ModelContext,
        scheduler: NotificationScheduling,
        widgetReloader: WidgetReloading,
        now: Date = .now
    ) async throws -> TaskSnoozeResult {
        guard let task = try? context.fetch(FetchDescriptor<KueTask>(predicate: #Predicate { $0.id == taskID })).first else {
            throw WidgetIntentError.taskNotFound
        }
        guard let event = task.event else {
            throw WidgetIntentError.taskEventUnavailable
        }
        guard let newDueDate = TaskSnoozeCalculator.snoozedDueDate(
            currentDueDate: task.dueDate,
            eventStartDate: event.startDate,
            timeZoneIdentifier: event.timeZoneIdentifier,
            now: now
        ) else {
            throw WidgetIntentError.noSnoozeIntervalRemains
        }

        let newLabel = TaskSnoozeCalculator.offsetLabel(
            newDueDate: newDueDate, eventStartDate: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier
        )
        task.dueDate = newDueDate
        task.offsetLabel = newLabel
        try? context.save()

        let identifier = "\(event.id)-\(NotificationTransitionKind.taskDue(taskID: task.id).identifierSuffix)"
        scheduler.removePendingNotificationRequests(withIdentifiers: [identifier])

        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        let status = await scheduler.authorizationStatus()
        if intensity == .all, status == .authorized || status == .provisional,
           let candidate = NotificationCandidateBuilder.candidates(for: event, now: now).first(where: { $0.kind == .taskDue(taskID: task.id) }) {
            await scheduler.add(candidate.makeRequest())
        }

        EventStatusEngine.sweep(context: context, now: now)
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)

        return TaskSnoozeResult(newDueDate: newDueDate, offsetLabel: newLabel)
    }

    struct EventCompletionResult: Equatable {
        var eventTitle: String
    }

    /// docs/07-widget-engine.md "CompleteEventIntent" — sets `isManuallyCompleted`, preserves
    /// the cancel/manual-complete mutual exclusion (docs/03 "Manual completion"), and removes
    /// *every* pending notification for the event, not just one transition's.
    @discardableResult
    static func completeEvent(
        eventID: UUID,
        context: ModelContext,
        scheduler: NotificationScheduling,
        widgetReloader: WidgetReloading,
        now: Date = .now
    ) throws -> EventCompletionResult {
        guard let event = try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })).first else {
            throw WidgetIntentError.eventNotFound
        }

        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        try? context.save()

        let identifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        if !identifiers.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        EventStatusEngine.sweep(context: context, now: now)
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)

        return EventCompletionResult(eventTitle: event.title)
    }
}
