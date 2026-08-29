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
    static func candidates(for event: KueEvent, now: Date = .now, reminderPreference: ReminderPreference = .current) -> [NotificationCandidate] {
        // Kue 2.0 Phase 3: a skipped occurrence shouldn't still fire its reminders, same as a
        // cancelled/completed one — see docs/17-recurring-events.md "Occurrence actions".
        guard event.status != .archived, !event.isCancelled, !event.isManuallyCompleted, !event.isSkipped else { return [] }

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
            case .awaitingOutcome:
                // Kue 2.0 Phase 10.1 — docs/25 "H." concept 6: reuses this exact transition
                // boundary (`effectiveEndDate`) rather than computing a second one — the
                // outcome follow-up fires exactly when the event *becomes* Awaiting Outcome.
                result.append(NotificationCandidate(
                    eventID: event.id, kind: .outcomeFollowUp, fireDate: date, isUrgentTier: true,
                    title: event.title,
                    body: "How did \(event.title) go?"
                ))
            case .countdown, .completed, .removed:
                // docs/08 defines no notification for the countdown phase itself (only its
                // preparation/tomorrow/today transitions); explicit completion is silent
                // ("V1 does not notify on completion, only updates the widget"), and removal
                // isn't a user-facing moment either.
                break
            }
        }

        // Kue 2.0 Phase 10.1 — docs/25 "H." concepts 4/5: computed directly from `startDate`,
        // not tied to a `WidgetLifecyclePhase` transition boundary — `.today`'s own boundary
        // is start-of-*day*, not the event's actual clock time.
        if let eventStart = eventStartCandidate(for: event, now: now) {
            result.append(eventStart)
        }
        if let preEvent = preEventCandidate(for: event, now: now, reminderPreference: reminderPreference) {
            result.append(preEvent)
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

    /// docs/25 "H." concept 5. Timed events fire exactly at `startDate`. All-day events never
    /// get a midnight "starting now" alert (meaningless — nothing actually starts at
    /// midnight) — instead a sensible pinned-timezone morning reminder (9:00 AM local to the
    /// event's own `timeZoneIdentifier`, never the device's).
    private static func eventStartCandidate(for event: KueEvent, now: Date) -> NotificationCandidate? {
        let fireDate = eventStartFireDate(for: event)
        guard fireDate > now else { return nil } // never schedule in the past
        return NotificationCandidate(
            eventID: event.id, kind: .eventStart, fireDate: fireDate, isUrgentTier: true,
            title: event.title,
            body: event.isAllDay ? "\(event.title) is today" : "\(event.title) is starting now"
        )
    }

    private static func eventStartFireDate(for event: KueEvent) -> Date {
        guard event.isAllDay else { return event.startDate }
        var calendar = WidgetContentService.calendar(for: event)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: event.startDate) ?? event.startDate
    }

    /// docs/25 "H." concept 4. `nil` (never scheduled) when the preference is Off or the
    /// event is all-day — an offset before an all-day event's normalized midnight `startDate`
    /// would itself land at a meaningless clock time (e.g. 11:30 PM the night before); the
    /// morning-of `.eventStart` reminder above already covers that case honestly.
    private static func preEventCandidate(for event: KueEvent, now: Date, reminderPreference: ReminderPreference) -> NotificationCandidate? {
        guard !event.isAllDay, let minutes = reminderPreference.preEventMinutes, minutes > 0 else { return nil }
        let fireDate = event.startDate.addingTimeInterval(-Double(minutes) * 60)
        guard fireDate > now else { return nil }
        return NotificationCandidate(
            eventID: event.id, kind: .preEvent, fireDate: fireDate, isUrgentTier: true,
            title: event.title,
            body: "\(event.title) starts in \(preEventDurationPhrase(minutes: minutes))"
        )
    }

    private static func preEventDurationPhrase(minutes: Int) -> String {
        guard minutes >= 60, minutes.isMultiple(of: 60) else { return "\(minutes) minutes" }
        let hours = minutes / 60
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// Every identifier this event could ever occupy, regardless of current intensity or
    /// whether it was actually ever scheduled — the exhaustive removal set docs/08 calls for
    /// on edit/cancel/complete ("each transition kind + each task's -task-<taskID>
    /// identifier"). Removing an identifier that was never pending is a harmless no-op.
    static func allIdentifiers(for event: KueEvent) -> [String] {
        var kinds: [NotificationTransitionKind] = [.preparationStart, .tomorrow, .today, .preEvent, .eventStart, .outcomeFollowUp]
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
