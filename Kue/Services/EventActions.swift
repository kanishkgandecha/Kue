//
//  EventActions.swift
//  Kue
//
//  See docs/04-event-types.md "Status transition rules" — the only three user-forceable
//  statuses (cancelled, manual-completed, archived), and their mutual-exclusivity/absorbing
//  behavior. Every mutation here re-derives `status` immediately afterward via
//  EventStatusEngine, so the persisted field never drifts from what these actions imply.
//
//  Every action also reloads the widget's timeline — docs/07-widget-engine.md "Refresh
//  strategy": SwiftData writes in one process aren't observed by the other, so a placed
//  widget only reflects a change once something explicitly asks WidgetKit to reload. Without
//  this, a widget keeps showing whatever its last precomputed timeline said until that
//  timeline's own next transition date arrives (which could be a fixed fallback interval
//  away, or never, for `.archived` events).
//
//  Phase 8 (M7): every action also keeps pending notifications in sync — docs/08-
//  notifications.md "Deduplication". Cancel/complete/archive/delete remove *all* of the
//  event's pending requests synchronously (unconditionally, per the doc); un-cancel/un-
//  complete/unarchive "revive" an event, so they re-run the full reschedule pass instead
//  (async — see NotificationEngine.reschedule) since the event may regain candidates.
//

import Foundation
import SwiftData
import WidgetKit

enum EventActions {
    /// Cancelling and manually completing are mutually exclusive — cancelling clears any
    /// prior manual completion.
    static func cancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) {
        event.isCancelled = true
        event.cancelledAt = now
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    static func uncancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) async {
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
    }

    /// Manually completing clears any prior cancellation — mirror of `cancel`.
    static func complete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) {
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    static func uncomplete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) async {
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
    }

    /// Immediate manual archive, independent of the auto-archive window.
    static func archive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) {
        event.status = .archived
        event.updatedAt = now
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    /// Restores an archived event to its freshly-derived, date-driven status.
    static func unarchive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) async {
        event.status = EventStatusEngine.derive(for: event, now: now)
        event.updatedAt = now
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
    }

    /// Cascade-deletes via the `.cascade` delete rules on KueEvent's relationships
    /// (docs/03-data-model.md "Relationships at a glance"). Identifiers are captured *before*
    /// the delete — once the event is gone, `NotificationEngine.reschedule`'s own self-healing
    /// pass can no longer reconstruct them, so this can't rely on that alone (unlike
    /// cancel/complete/archive, which leave the event in the store).
    static func delete(_ event: KueEvent, context: ModelContext, scheduler: NotificationScheduling = SystemNotificationScheduler.shared) {
        let identifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        context.delete(event)
        try? context.save()
        reloadWidget()
        if !identifiers.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    /// Fire-and-forget — safe to call even when no widget is placed, and safe to call from
    /// the test host process (it just no-ops if there's nothing to reload).
    static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.kue)
    }

    private static func rescheduleNotifications(context: ModelContext, scheduler: NotificationScheduling, now: Date) async {
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: scheduler, now: now)
    }
}
