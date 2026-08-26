//
//  NotificationCandidateBuilder.swift
//  Kue
//
//  See docs/08-notifications.md "Scheduling model" — "the notification engine [gets] the
//  same list of (date, kind) transition points [as] the widget engine," i.e.
//  `WidgetContentService.transitionPlan(for:now:)`. Pure Foundation, no SwiftData/
//  UNUserNotificationCenter — independently testable the same way WidgetContentService is.
//

import Foundation

enum NotificationCandidateBuilder {
    /// Every candidate this event could produce right now. Deliberately excludes archived,
    /// cancelled, and manually-completed events — docs/08 "Deduplication": "the user no
    /// longer cares about" a cancelled/completed event. `WidgetContentService.transitionPlan`
    /// itself only guards `.archived` (a widget-engine concern this file doesn't alter), so
    /// this guard is stricter on purpose.
    static func candidates(for event: KueEvent, now: Date = .now) -> [NotificationCandidate] {
        guard event.status != .archived, !event.isCancelled, !event.isManuallyCompleted else { return [] }

        var result: [NotificationCandidate] = []
        for (date, phase) in WidgetContentService.transitionPlan(for: event, now: now) {
            switch phase {
            case .preparation:
                result.append(NotificationCandidate(
                    eventID: event.id, kind: .preparationStart, fireDate: date, isUrgentTier: false,
                    title: event.title,
                    body: "Your \(event.title) preparation starts today"
                ))
            case .tomorrow:
                let isUrgent = WidgetContentService.isUrgentTreatment(eventType: event.eventType, phase: .tomorrow)
                result.append(NotificationCandidate(
                    eventID: event.id, kind: .tomorrow, fireDate: date, isUrgentTier: isUrgent,
                    title: event.title,
                    body: tomorrowBody(for: event)
                ))
            case .today:
                result.append(NotificationCandidate(
                    eventID: event.id, kind: .today, fireDate: date, isUrgentTier: true,
                    title: event.title,
                    body: todayBody(for: event)
                ))
            case .countdown, .completed, .removed:
                // docs/08 defines no notification for the countdown phase itself (only its
                // preparation/tomorrow/today transitions); completion is explicitly silent
                // ("V1 does not notify on completion, only updates the widget"), and removal
                // isn't a user-facing moment either.
                break
            }
        }

        // "Task due" — every incomplete task's own due date, `all` intensity only (filtered
        // by the caller, not here, so this builder stays a single source of truth).
        for task in event.tasks where !task.isCompleted && task.dueDate > now {
            result.append(NotificationCandidate(
                eventID: event.id, kind: .taskDue(taskID: task.id), fireDate: task.dueDate, isUrgentTier: false,
                title: event.title,
                body: "Today: \(task.title)"
            ))
        }
        return result
    }

    /// Every identifier this event could ever occupy, regardless of current intensity or
    /// whether it was actually ever scheduled — the exhaustive removal set docs/08 calls for
    /// on edit/cancel/complete ("each transition kind + each task's -task-<taskID>
    /// identifier"). Removing an identifier that was never pending is a harmless no-op.
    static func allIdentifiers(for event: KueEvent) -> [String] {
        var kinds: [NotificationTransitionKind] = [.preparationStart, .tomorrow, .today]
        kinds += event.tasks.map { .taskDue(taskID: $0.id) }
        return kinds.map { "\(event.id)-\($0.identifierSuffix)" }
    }

    /// docs/08-notifications.md "User control over intensity".
    static func filter(_ candidates: [NotificationCandidate], intensity: NotificationIntensity) -> [NotificationCandidate] {
        candidates.filter { candidate in
            switch intensity {
            case .minimal:
                return candidate.priorityTier == 0
            case .standard:
                if case .taskDue = candidate.kind { return false }
                return true
            case .all:
                return true
            }
        }
    }

    /// docs/08-notifications.md "Priority-ordered fill": "sort ... by date ascending first,
    /// then by category as a tie-break" — a near-term reminder is never dropped for a distant
    /// one just because of category.
    static func prioritized(_ candidates: [NotificationCandidate]) -> [NotificationCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            if lhs.priorityTier != rhs.priorityTier { return lhs.priorityTier < rhs.priorityTier }
            return lhs.identifier < rhs.identifier // deterministic final tie-break
        }
    }

    private static func tomorrowBody(for event: KueEvent) -> String {
        let remaining = event.tasks.count { !$0.isCompleted }
        let base = "Your \(event.title) is tomorrow"
        guard remaining > 0 else { return base }
        return "\(base) — \(remaining) task\(remaining == 1 ? "" : "s") remaining"
    }

    private static func todayBody(for event: KueEvent) -> String {
        guard !event.isAllDay else { return "Your \(event.title) is today" }
        let time = event.startDate.formatted(date: .omitted, time: .shortened)
        return "Your \(event.title) is today at \(time)"
    }
}
