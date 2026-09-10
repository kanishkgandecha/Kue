//
//  LiveActivityStateBuilder.swift
//  Kue
//
//  Pure `KueEvent`(?) + `now` → `KueLiveActivityAttributes.ContentState` — no ActivityKit
//  calls, no SwiftData writes, no fetches. Reuses `DedicatedWidgetContentService.resolve`
//  (Phase 8) for the exact same tracking/cancelled/skipped/unavailable resolution the
//  Dedicated Countdown widget already uses, so a Live Activity and that widget can never
//  disagree about the same event's state at the same instant — see docs/23
//  "ActivityKit attributes/state contract."
//
//  Kue 3.0 Phase 1 (macOS Foundation) — guarded like `KueLiveActivityAttributes.swift` itself
//  (the type this whole file builds); see that file's header.
//

#if os(iOS)
import Foundation

enum LiveActivityStateBuilder {
    /// The privacy-aware attributes for a *new* activity request — set once and never
    /// changed for the activity's lifetime (docs/23 "One-event focus invariant": identity
    /// is pinned to this exact occurrence row).
    static func attributes(for event: KueEvent) -> KueLiveActivityAttributes {
        KueLiveActivityAttributes(
            eventID: event.id,
            eventType: event.eventType,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier
        )
    }

    /// The normal, event-still-exists path.
    static func contentState(
        for event: KueEvent,
        now: Date = .now,
        privacy: LiveActivityPrivacyPreference = .current
    ) -> KueLiveActivityAttributes.ContentState {
        contentState(
            from: DedicatedWidgetContentService.resolve(event: event, now: now),
            fallbackEventType: event.eventType,
            eventStartDate: event.startDate,
            eventEffectiveEndDate: event.effectiveEndDate,
            now: now,
            privacy: privacy
        )
    }

    /// The event no longer exists in the shared store — there's no `KueEvent` left to read,
    /// only what the activity's own immutable `Attributes.eventType` still remembers. Always
    /// `.unavailable`, never any other terminal case (docs/23 "Terminal-state policy": a
    /// deleted event is the one case with no live row to distinguish cancelled from skipped).
    static func unavailableContentState(eventType: EventType, now: Date = .now) -> KueLiveActivityAttributes.ContentState {
        KueLiveActivityAttributes.ContentState(
            displayTitle: genericLabel(for: eventType),
            eventTypeDisplayName: eventType.displayName,
            phase: .removed,
            isUrgent: false,
            effectiveStartDate: now,
            effectiveEndDate: now,
            countdownSubline: nil,
            tasksCompleted: 0,
            tasksTotal: 0,
            nextTaskID: nil,
            nextTaskSummary: nil,
            remainingTaskCount: 0,
            canSnoozeNextTask: false,
            terminal: .unavailable,
            lastUpdated: now
        )
    }

    /// docs/23 "Privacy matrix": "replace title with a generic event-type label" —
    /// e.g. "Exam," not the real title, and never "Upcoming Event" alone once a real type is
    /// known (that generic fallback is reserved for the truly-unavailable case above, where
    /// even the type reads as more informative than nothing).
    static func genericLabel(for eventType: EventType) -> String {
        eventType.displayName
    }

    private static func contentState(
        from resolution: DedicatedWidgetResolution,
        fallbackEventType: EventType,
        eventStartDate: Date,
        eventEffectiveEndDate: Date,
        now: Date,
        privacy: LiveActivityPrivacyPreference
    ) -> KueLiveActivityAttributes.ContentState {
        switch resolution {
        case .tracking(let content):
            let nextTask = content.tasks.first { !$0.isCompleted }
            return KueLiveActivityAttributes.ContentState(
                displayTitle: privacy.showTitle ? content.eventTitle : genericLabel(for: fallbackEventType),
                eventTypeDisplayName: content.eventTypeDisplayName,
                phase: content.phase,
                isUrgent: content.isUrgent,
                // Kue 3.0 Phase 2 fix — these two fields previously always carried `now` (a
                // decorative placeholder, never the real event window), which left no data
                // for a compact "3h"/"Now" countdown to be computed from. They now carry the
                // real, already-known event timestamps `LiveActivityCompactCountdown` (Shared/)
                // formats — still not a new status derivation: `phase`/`terminal` above remain
                // the one source of lifecycle truth, this is presentation math over dates the
                // event already had.
                effectiveStartDate: eventStartDate,
                effectiveEndDate: eventEffectiveEndDate,
                countdownSubline: content.subline,
                tasksCompleted: content.tasksCompleted,
                tasksTotal: content.tasksTotal,
                nextTaskID: nextTask?.id,
                nextTaskSummary: (privacy.showNextTask ? nextTask?.title : nil),
                remainingTaskCount: content.tasksTotal - content.tasksCompleted,
                canSnoozeNextTask: content.canSnooze,
                terminal: nil,
                lastUpdated: now
            )
        case .cancelled(_, let title), .skipped(_, let title):
            let terminal: KueLiveActivityAttributes.ContentState.Terminal = {
                if case .cancelled = resolution { return .cancelled }
                return .skipped
            }()
            return KueLiveActivityAttributes.ContentState(
                displayTitle: privacy.showTitle ? title : genericLabel(for: fallbackEventType),
                eventTypeDisplayName: fallbackEventType.displayName,
                phase: .today,
                isUrgent: false,
                effectiveStartDate: eventStartDate,
                effectiveEndDate: eventEffectiveEndDate,
                countdownSubline: nil,
                tasksCompleted: 0,
                tasksTotal: 0,
                nextTaskID: nil,
                nextTaskSummary: nil,
                remainingTaskCount: 0,
                canSnoozeNextTask: false,
                terminal: terminal,
                lastUpdated: now
            )
        case .unavailable:
            return unavailableContentState(eventType: fallbackEventType, now: now)
        }
    }
}
#endif
