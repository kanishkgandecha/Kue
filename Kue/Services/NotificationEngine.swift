//
//  NotificationEngine.swift
//  Kue
//
//  See docs/08-notifications.md "Scheduling model" / "Deduplication" / "Pending-notification
//  limit" / "Permission handling". The SwiftData-touching orchestration layer — everything
//  in NotificationCandidate(Builder).swift above this is pure and doesn't know
//  UNUserNotificationCenter exists.
//

import Foundation
import SwiftData
import UserNotifications

enum NotificationEngine {
    /// iOS's hard cap — docs/08-notifications.md "Pending-notification limit (iOS cap)".
    static let pendingRequestCap = 64

    /// The single entry point that keeps pending requests in sync with the current desired
    /// state across every non-archived event. Self-healing by design: it recomputes the full
    /// candidate set from scratch every call rather than diffing incrementally against what
    /// this one event used to have, so both "stale identifiers from an edit" (requirement 4)
    /// and "identifiers trimmed by a prior cap-fill, now free to come back" (requirement 6's
    /// replenishment) are corrected the same way, across every event, not just the one that
    /// triggered the call. Call after any mutation that can change an event's candidate set
    /// (create, edit, custom-schedule save, revival from cancel/complete/archive) and from
    /// the passive replenishment triggers (foreground, `BGAppRefreshTask`).
    ///
    /// `requestPermissionIfNeeded` should only be `true` at the doc-specified "first point
    /// it's needed" (creating/editing an event) — docs/08 "Permission handling": requested
    /// "at the first point it's needed ... not at app launch." Passive triggers (foreground
    /// sweep, background refresh) pass `false` so they never surprise the user with a prompt.
    static func reschedule(
        context: ModelContext,
        intensity: NotificationIntensity,
        scheduler: NotificationScheduling,
        now: Date = .now,
        requestPermissionIfNeeded: Bool = false,
        reminderPreference: ReminderPreference? = nil
    ) async {
        let reminderPreference = reminderPreference ?? .current
        var status = await scheduler.authorizationStatus()
        if status == .notDetermined && requestPermissionIfNeeded {
            _ = await scheduler.requestAuthorization()
            status = await scheduler.authorizationStatus()
        }
        // Requirement 9: not-determined and denied both mean "schedule nothing," gracefully —
        // never crash, never block the caller's own event mutation, which has already
        // committed by the time this runs.
        guard status == .authorized || status == .provisional else { return }

        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let allKnownIdentifiers = Set(events.flatMap(NotificationCandidateBuilder.allIdentifiers))
        let allCandidates = events.flatMap { NotificationCandidateBuilder.candidates(for: $0, now: now, reminderPreference: reminderPreference) }
        let desired = NotificationCandidateBuilder.prioritized(
            NotificationCandidateBuilder.filter(allCandidates, intensity: intensity)
        )
        // Requirement 6: keep the nearest `pendingRequestCap` by (date, tier); anything past
        // the cap is left unscheduled for now, picked back up next replenishment.
        let toSchedule = Array(desired.prefix(pendingRequestCap))
        let desiredIdentifiers = Set(toSchedule.map(\.identifier))

        let toRemove = allKnownIdentifiers.subtracting(desiredIdentifiers)
        if !toRemove.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: Array(toRemove))
        }
        for candidate in toSchedule {
            await scheduler.add(candidate.makeRequest())
        }
    }

    /// docs/08-notifications.md "Deduplication": "Completing or cancelling an event removes
    /// *all* of its pending requests, not just one transition's ... unconditionally." Also
    /// used for delete, where the event is about to leave the store entirely and so can't be
    /// recovered by `reschedule`'s own self-healing pass afterward.
    static func removeAllNotifications(for event: KueEvent, scheduler: NotificationScheduling) {
        let identifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        guard !identifiers.isEmpty else { return }
        scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
