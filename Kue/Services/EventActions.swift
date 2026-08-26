//
//  EventActions.swift
//  Kue
//
//  See docs/04-event-types.md "Status transition rules" — the only three user-forceable
//  statuses (cancelled, manual-completed, archived), and their mutual-exclusivity/absorbing
//  behavior. Every mutation here re-derives `status` immediately afterward via
//  EventStatusEngine, so the persisted field never drifts from what these actions imply.
//

import Foundation
import SwiftData

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
    }

    static func uncancel(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
    }

    /// Manually completing clears any prior cancellation — mirror of `cancel`.
    static func complete(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isManuallyCompleted = true
        event.manuallyCompletedAt = now
        event.isCancelled = false
        event.cancelledAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
    }

    static func uncomplete(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.isManuallyCompleted = false
        event.manuallyCompletedAt = nil
        EventStatusEngine.reconcile(event, now: now)
        try? context.save()
    }

    /// Immediate manual archive, independent of the auto-archive window.
    static func archive(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.status = .archived
        event.updatedAt = now
        try? context.save()
    }

    /// Restores an archived event to its freshly-derived, date-driven status.
    static func unarchive(_ event: KueEvent, context: ModelContext, now: Date = .now) {
        event.status = EventStatusEngine.derive(for: event, now: now)
        event.updatedAt = now
        try? context.save()
    }

    /// Cascade-deletes via the `.cascade` delete rules on KueEvent's relationships
    /// (docs/03-data-model.md "Relationships at a glance").
    static func delete(_ event: KueEvent, context: ModelContext) {
        context.delete(event)
        try? context.save()
    }
}
