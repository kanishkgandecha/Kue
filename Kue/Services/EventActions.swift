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

import Foundation
import SwiftData
import WidgetKit

enum EventActions {
    /// Cancelling and manually completing are mutually exclusive — cancelling clears any
    /// prior manual completion.
    static func cancel(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isCancelled = true
        event.cancelledAt = now
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
    }

    static func uncancel(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
    }

    /// Manually completing clears any prior cancellation — mirror of `cancel`.
    static func complete(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
    }

    static func uncomplete(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
        reloadWidget()
    }

    /// Immediate manual archive, independent of the auto-archive window.
    static func archive(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.status = .archived
        event.updatedAt = now
        try? context.save()
        reloadWidget()
    }

    /// Restores an archived event to its freshly-derived, date-driven status.
    static func unarchive(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.status = EventStatusEngine.derive(for: event, now: now)
        event.updatedAt = now
        try? context.save()
        reloadWidget()
    }

    /// Cascade-deletes via the `.cascade` delete rules on KueEvent's relationships
    /// (docs/03-data-model.md "Relationships at a glance").
    static func delete(_ event: KueEvent, context: ModelContext) {
        context.delete(event)
        try? context.save()
        reloadWidget()
    }

    /// Fire-and-forget — safe to call even when no widget is placed, and safe to call from
    /// the test host process (it just no-ops if there's nothing to reload).
    static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.kue)
    }
}
