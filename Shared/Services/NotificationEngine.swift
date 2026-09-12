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
    @discardableResult
    static func reschedule(
        context: ModelContext,
        intensity: NotificationIntensity,
        scheduler: NotificationScheduling,
        now: Date = .now,
        requestPermissionIfNeeded: Bool = false,
        reminderPreference: ReminderPreference? = nil,
        globalPreferences: NotificationGlobalPreferences? = nil,
        // Kue 3.0 Phase 7 — docs/35: injectable for tests; the real call sites always read the
        // current per-device preferences, same pattern `globalPreferences` itself already uses.
        eventTypeRules: EventTypeNotificationPreferences? = nil,
        calendar: Calendar = .current
    ) async -> NotificationSchedulePlan {
        // `reminderPreference` stays an explicit override parameter (tests / call sites that
        // still pass one directly keep working) but no longer drives the plan on its own —
        // `NotificationGlobalPreferences.defaultPreEventMinutes` is the real source of truth
        // now; when a caller passes `reminderPreference` explicitly, it wins, matching this
        // parameter's pre-existing "explicit override" contract.
        let globalPreferences = { () -> NotificationGlobalPreferences in
            var prefs = globalPreferences ?? .current
            if let reminderPreference { prefs.defaultPreEventMinutes = reminderPreference.preEventMinutes }
            return prefs
        }()

        var status = await scheduler.authorizationStatus()
        if status == .notDetermined && requestPermissionIfNeeded {
            _ = await scheduler.requestAuthorization()
            status = await scheduler.authorizationStatus()
        }
        let authorizationGranted = status == .authorized || status == .provisional

        let eventTypeRules = eventTypeRules ?? .current
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let plan = NotificationPlanner.plan(NotificationPlanner.Input(
            events: events, globalPreferences: globalPreferences, eventTypeRules: eventTypeRules,
            intensity: intensity, authorizationGranted: authorizationGranted, now: now,
            calendar: calendar, capacity: pendingRequestCap
        ))

        // Every identifier this event/task graph could ever occupy — `allIdentifiers` (Shared/)
        // already covers both the default layer's own exhaustive set (docs/08) and every
        // rule's own `"<event>-rule-<rule>"` form, including disabled/invalid/excluded ones, so
        // a since-disabled or since-invalidated rule's stale pending request is still cleanly
        // removed (docs/31 "Scheduling executor": "Use stable identifiers so rescheduling
        // replaces the correct pending request"). Kue 3.0 Phase 7 — docs/35: also every
        // currently-known event-type-sourced identifier for each event's own type (so a
        // since-disabled event-type default is cleanly removed too) and the two fixed Daily/
        // Weekly Summary identifiers (always known, regardless of whether either is currently
        // enabled, so disabling one cleanly removes its stale pending request).
        var knownIdentifiers = Set(events.flatMap(NotificationCandidateBuilder.allIdentifiers))
        for event in events {
            for def in eventTypeRules.rules(for: event.eventType) {
                knownIdentifiers.insert("\(event.id)-eventtype-\(event.eventType.rawValue)-\(def.id)")
            }
        }
        knownIdentifiers.insert("daily-summary")
        knownIdentifiers.insert("weekly-summary")

        // Requirement 9 (docs/08): not-determined/denied both mean "schedule nothing,"
        // gracefully — `NotificationPlanner` already excluded every candidate with
        // `.permissionDenied` above when `authorizationGranted` is false, so this reconcile
        // call still runs (removing anything stale) rather than early-returning and leaving
        // old requests behind.
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: knownIdentifiers, scheduler: scheduler, globalPreferences: globalPreferences)
        return plan
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
