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
    static func cancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        event.isCancelled = true
        event.cancelledAt = now
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
        reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    static func uncancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Manually completing clears any prior cancellation — mirror of `cancel`.
    static func complete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
        reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    static func uncomplete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Kue 2.0 Phase 3 — docs/17-recurring-events.md "Occurrence actions": the third
    /// mutually-exclusive user-forceable state, alongside cancel/manual-complete. Reuses
    /// `.cancelled` as the derived `EventStatus` (see `EventStatusEngine.derive`) so every
    /// existing consumer that already excludes cancelled events excludes a skip for free.
    /// Also marks `isRecurrenceException` — a skip is a deviation from the rule and must never
    /// be silently regenerated by replenishment.
    static func skip(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        event.isSkipped = true
        event.skippedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        event.isRecurrenceException = true
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
        reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    static func unskip(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isSkipped = false
        event.skippedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Immediate manual archive, independent of the auto-archive window.
    static func archive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        event.status = .archived
        event.updatedAt = now
        try? context.save()
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
        reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    /// Restores an archived event to its freshly-derived, date-driven status.
    static func unarchive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.status = EventStatusEngine.derive(for: event, now: now)
        event.updatedAt = now
        try? context.save()
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Cascade-deletes via the `.cascade` delete rules on KueEvent's relationships
    /// (docs/03-data-model.md "Relationships at a glance"). Identifiers are captured *before*
    /// the delete — once the event is gone, `NotificationEngine.reschedule`'s own self-healing
    /// pass can no longer reconstruct them, so this can't rely on that alone (unlike
    /// cancel/complete/archive, which leave the event in the store). Captures the id first for
    /// the same reason, so the Live Activity reconciliation below still knows which activity
    /// (if any) needs to move to `.unavailable`.
    static func delete(_ event: KueEvent, context: ModelContext, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        let identifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        let deletedID = event.id
        context.delete(event)
        try? context.save()
        reloadWidget()
        if !identifiers.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        reconcileLiveActivity(context: context, manager: liveActivityManager, now: .now)
        Task { await spotlightIndexer.remove(eventIDs: [deletedID]) }
    }

    /// Fire-and-forget — safe to call even when no widget is placed, and safe to call from
    /// the test host process (it just no-ops if there's nothing to reload). Kue 2.0 Phase 8/9
    /// — reloads both widget kinds: a mutation made from the app can affect a Dedicated
    /// Countdown instance pinned to this event too, same reasoning
    /// `WidgetIntentActions.reloadAllWidgetKinds` already documents for the widget-triggered
    /// path (this was a genuine pre-Phase-9 gap — `EventActions` only ever reloaded `.kue`).
    static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.kue)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.dedicatedCountdown)
    }

    private static func rescheduleNotifications(context: ModelContext, scheduler: NotificationScheduling, now: Date) async {
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: scheduler, now: now)
    }

    /// Kue 2.0 Phase 9 — the app process stays alive well past a button tap (unlike a widget
    /// extension's `perform()`), so a detached `Task` here is safe and avoids making every
    /// synchronous action in this file `async` (which would ripple into every button call
    /// site and every existing synchronous `EventActionsNotificationTests`/`EventCRUDTests`
    /// call, for no behavioral benefit — the widget-extension-triggered path in
    /// `WidgetIntentActions` *does* need to `await` this directly, since that process can be
    /// suspended immediately after returning).
    private static func reconcileLiveActivity(context: ModelContext, manager: LiveActivityManaging, now: Date) {
        Task { await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now) }
    }

    /// Kue 2.0 Phase 10 — same fire-and-forget reasoning as `reconcileLiveActivity` above,
    /// bundled together since every synchronous terminal-state action needs both: the Live
    /// Activity reconciled *and* Spotlight's copy of this event's status/title kept current
    /// (docs/24 "G."). `event` (not just its id) is captured before the `Task` starts so a
    /// caller that mutates the same object again immediately after still reads consistently —
    /// SwiftData model objects are reference types, so this closure sees the state as of
    /// whenever the Task actually runs, same as `reconcileLiveActivity`'s own `context` capture.
    private static func reconcileAfterMutation(_ event: KueEvent, context: ModelContext, manager: LiveActivityManaging, indexer: SpotlightIndexing, now: Date) {
        reconcileLiveActivity(context: context, manager: manager, now: now)
        Task { await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)]) }
    }
}
