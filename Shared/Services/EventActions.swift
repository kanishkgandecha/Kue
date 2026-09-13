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
//  Kue 3.0 Phase 8 correction pass — docs/36 "Reconciliation lifetime": `cancel`/`complete`/
//  `skip`/`archive` are synchronous convenience wrappers that fire Live Activity/Spotlight
//  reconciliation via an *unawaited* `Task`. That's genuinely safe when the caller is the
//  main app's own long-lived process and the mutating view has nothing further to do (a
//  Home/Event Detail button tap — the container/context these Tasks capture is the app-scoped
//  `ModelContainer.mainContext`, alive for the whole process lifetime, so a sheet dismissing or
//  a view tearing down underneath it changes nothing). It is **not** safe wherever the calling
//  process/continuation can be suspended immediately after the mutating call returns — found by
//  direct audit to be a real, pre-existing condition (not hypothetical) at three call sites:
//  `CancelEventIntent`/`CompleteEventIntent`/`SkipEventIntent` (App Intents with
//  `openAppWhenRun = false`, which the system can suspend right after `perform()` returns) and
//  `NotificationActionHandler.handle` (its caller invokes the delegate's `completionHandler()`
//  immediately after `handle` returns, which is the documented signal telling the system it may
//  suspend the process). Each terminal action below therefore has two forms: the original sync
//  wrapper (fire-and-forget, kept for the ~40 already-safe UI call sites) and a new `...
//  AwaitingReconciliation` async twin that performs the identical mutation and then genuinely
//  awaits Live Activity + Spotlight reconciliation before returning — used by the three App
//  Intents above, `NotificationActionHandler`, `PlanningActionRouter`, and any test that needs
//  a deterministic completion signal instead of an arbitrary sleep. Mutation semantics
//  (`isCancelled`/`isManuallyCompleted`/etc., notification removal, sync-outbox marking, widget
//  reload) are identical between the two forms — only how the trailing reconciliation is
//  awaited differs. Account switching/sign-out (`AccountCoordinator.signOut`) and backup
//  restore never call these functions at all and never recreate/tear down the shared
//  `ModelContainer` (confirmed by direct inspection — Kue's local store is a single,
//  account-agnostic, process-lifetime singleton; Personal/local-only mode is exactly this
//  already), so neither is a real risk vector for this lifetime hazard in this codebase today.
//

import Foundation
import SwiftData
import WidgetKit

enum EventActions {
    /// Cancelling and manually completing are mutually exclusive — cancelling clears any
    /// prior manual completion. Fire-and-forget reconciliation — see this file's own header
    /// for exactly which callers this is (and isn't) safe for. Idempotent: calling this again
    /// on an already-cancelled event re-applies the same field values and re-runs
    /// reconciliation harmlessly (notification removal/Live-Activity/Spotlight are themselves
    /// idempotent — see `EventActionsReconciliationTests`).
    static func cancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        applyCancel(event, context: context, now: now, scheduler: scheduler)
        Task { await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now) }
    }

    /// Deterministic twin of `cancel` — identical mutation, but returns only once Live
    /// Activity + Spotlight reconciliation has actually finished. Required wherever the
    /// caller's own process/continuation can be suspended immediately after returning (App
    /// Intents, notification actions) or wherever a test needs a real completion signal
    /// instead of an arbitrary sleep — see this file's own header.
    static func cancelAwaitingReconciliation(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        applyCancel(event, context: context, now: now, scheduler: scheduler)
        await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    private static func applyCancel(_ event: KueEvent, context: ModelContext, now: Date, scheduler: NotificationScheduling) {
        event.isCancelled = true
        event.cancelledAt = now
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        // Kue 2.0 Phase 11 — docs/26 "H.": `updatedAt` is the CloudKit conflict-resolution
        // timestamp for this event's whole graph, so every explicit user mutation must bump
        // it. A real pre-Phase-11 gap (found during the sync audit): only `archive`/
        // `unarchive` did this before; the other six mutating actions here didn't.
        event.updatedAt = now
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    static func uncancel(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isCancelled = false
        event.cancelledAt = nil
        event.updatedAt = now // Kue 2.0 Phase 11 — see `cancel`'s own comment above.
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Manually completing clears any prior cancellation — mirror of `cancel`. See `cancel`'s
    /// own comment for the fire-and-forget-safety/idempotency notes that apply identically here.
    static func complete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        applyComplete(event, context: context, now: now, scheduler: scheduler)
        Task { await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now) }
    }

    /// Deterministic twin of `complete` — see `cancelAwaitingReconciliation`'s own comment.
    static func completeAwaitingReconciliation(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        applyComplete(event, context: context, now: now, scheduler: scheduler)
        await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    private static func applyComplete(_ event: KueEvent, context: ModelContext, now: Date, scheduler: NotificationScheduling) {
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        event.updatedAt = now // Kue 2.0 Phase 11 — see `cancel`'s own comment above.
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    static func uncomplete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        event.updatedAt = now // Kue 2.0 Phase 11 — see `cancel`'s own comment above.
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
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
        applySkip(event, context: context, now: now, scheduler: scheduler)
        Task { await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now) }
    }

    /// Deterministic twin of `skip` — see `cancelAwaitingReconciliation`'s own comment.
    static func skipAwaitingReconciliation(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        applySkip(event, context: context, now: now, scheduler: scheduler)
        await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    private static func applySkip(_ event: KueEvent, context: ModelContext, now: Date, scheduler: NotificationScheduling) {
        event.isSkipped = true
        event.skippedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        event.isRecurrenceException = true
        event.updatedAt = now // Kue 2.0 Phase 11 — see `cancel`'s own comment above.
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    static func unskip(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.isSkipped = false
        event.skippedAt = nil
        event.updatedAt = now // Kue 2.0 Phase 11 — see `cancel`'s own comment above.
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        await rescheduleNotifications(context: context, scheduler: scheduler, now: now)
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Immediate manual archive, independent of the auto-archive window.
    static func archive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        applyArchive(event, context: context, now: now, scheduler: scheduler)
        Task { await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now) }
    }

    /// Deterministic twin of `archive` — see `cancelAwaitingReconciliation`'s own comment.
    static func archiveAwaitingReconciliation(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        applyArchive(event, context: context, now: now, scheduler: scheduler)
        await reconcileAfterMutation(event, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    private static func applyArchive(_ event: KueEvent, context: ModelContext, now: Date, scheduler: NotificationScheduling) {
        event.status = .archived
        event.updatedAt = now
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
        reloadWidget()
        NotificationEngine.removeAllNotifications(for: event, scheduler: scheduler)
    }

    /// Restores an archived event to its freshly-derived, date-driven status.
    static func unarchive(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        event.status = EventStatusEngine.derive(for: event, now: now)
        event.updatedAt = now
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": every explicit mutation enqueues sync work
        // durably, immediately after the local save already succeeded — never gated on it.
        SyncOutbox.markEventDirty(event.id)
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
    static func delete(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) {
        let deletedID = applyDelete(event, context: context, now: now, scheduler: scheduler)
        Task { await reconcileAfterDelete(deletedID, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now) }
    }

    /// Deterministic twin of `delete` — see `cancelAwaitingReconciliation`'s own comment. Not
    /// currently called from any App Intent/notification-action path (only UI and
    /// `OccurrenceReconciliationService`, both already safe), but exposed for the same
    /// future-proofing/testability reason the other four terminal actions have one.
    static func deleteAwaitingReconciliation(_ event: KueEvent, context: ModelContext, now: Date = .now, scheduler: NotificationScheduling = SystemNotificationScheduler.shared, liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared, spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared) async {
        let deletedID = applyDelete(event, context: context, now: now, scheduler: scheduler)
        await reconcileAfterDelete(deletedID, context: context, manager: liveActivityManager, indexer: spotlightIndexer, now: now)
    }

    @discardableResult
    private static func applyDelete(_ event: KueEvent, context: ModelContext, now: Date, scheduler: NotificationScheduling) -> UUID {
        let identifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        let deletedID = event.id
        context.delete(event)
        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": a deletion enqueues a tombstone, not a dirty-upload
        // mark — see `SyncOutbox.markEventDeleted`'s own header.
        SyncOutbox.markEventDeleted(deletedID, now: now)
        reloadWidget()
        if !identifiers.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        return deletedID
    }

    private static func reconcileAfterDelete(_ deletedID: UUID, context: ModelContext, manager: LiveActivityManaging, indexer: SpotlightIndexing, now: Date) async {
        await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        await indexer.remove(eventIDs: [deletedID])
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

    /// Kue 3.0 Phase 8 correction pass — the one place Live Activity + Spotlight reconciliation
    /// actually happens after a terminal mutation, for both the fire-and-forget sync wrappers
    /// (called from inside their own `Task { await ... }`) and the `...AwaitingReconciliation`
    /// twins (called directly, `await`ed by the caller). No child `Task` is spawned here
    /// itself — previously this split into two separately-orphaned Tasks (one for Live
    /// Activity, one for Spotlight), which is exactly what made "wait for reconciliation to
    /// finish" impossible to express deterministically; awaiting both sequentially in one
    /// place is what makes the `...AwaitingReconciliation` variants a real, awaitable
    /// completion signal. `event` (not just its id) is captured by value from the caller before
    /// this runs, so a caller that mutates the same object again immediately after still reads
    /// consistently.
    private static func reconcileAfterMutation(_ event: KueEvent, context: ModelContext, manager: LiveActivityManaging, indexer: SpotlightIndexing, now: Date) async {
        await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }
}
