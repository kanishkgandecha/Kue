//
//  EventStatusEngine.swift
//  Kue
//
//  See docs/04-event-types.md "Status transition rules" / "Reconciliation". Pure derivation
//  + the write-back ("reconcile") the docs call for. `status` is never set anywhere else in
//  the app except through this file and the explicit archive/unarchive actions in
//  EventActions.swift.
//
//  Spec gap (recorded in docs/14-open-questions.md): 04-event-types.md's EventStatus enum has
//  `.preparing` alongside `.upcoming`/`.tomorrow`/`.today`, but the pure function's inputs
//  (startDate, effectiveEndDate, now, isCancelled, isManuallyCompleted) never say what day
//  threshold makes an event "preparing" — that boundary only exists per-event-type in
//  05-scheduling-engine.md's rule templates (7d/14d/etc.), which Phase 3 hasn't built yet.
//  `derive(for:)` below never returns `.preparing` in Phase 2; folding it into `.upcoming`
//  until real per-type templates exist is the documented-gap decision, not a silent one.
//

import Foundation
import SwiftData

enum EventStatusEngine {
    /// Days after reaching `.completed`/`.cancelled` before auto-archiving.
    /// docs/04-event-types.md: "default: 3 days — configurable later, hardcode for V1."
    static let autoArchiveDays = 3

    /// The pure function: `(startDate, effectiveEndDate, now, isCancelled, isManuallyCompleted)
    /// → EventStatus`. Never reads or writes `event.status` itself — callers decide whether
    /// (and how) to persist the result. Never returns `.draft` or `.archived`; those are not
    /// date-derived (see `reconcile(_:now:)` for archive handling).
    static func derive(for event: KueEvent, now: Date = .now) -> EventStatus {
        if event.isCancelled { return .cancelled }
        if event.isManuallyCompleted { return .completed }

        let end = event.effectiveEndDate
        if now >= end { return .completed }
        // All-day events never pass through `.active` — they stay `.today` for the whole
        // calendar day and jump straight to `.completed` at the following midnight (the `end`
        // check above). Without this guard, `now >= event.startDate` alone would wrongly
        // fire the instant an all-day event's midnight arrives.
        if !event.isAllDay, now >= event.startDate { return .active }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        let nowDay = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: event.startDate)
        let daysUntil = calendar.dateComponents([.day], from: nowDay, to: startDay).day ?? 0

        switch daysUntil {
        case 0: return .today
        case 1: return .tomorrow
        default: return .upcoming
        }
    }

    /// Recomputes and persists `event.status`, respecting archive as a terminal override that
    /// this function never reverts (an archived event stays archived until an explicit
    /// `EventActions.unarchive`). Applies the auto-archive threshold on top of the derived
    /// status. Returns whether `status` actually changed.
    @discardableResult
    static func reconcile(_ event: KueEvent, now: Date = .now) -> Bool {
        guard event.status != .archived else { return false }

        let derived = derive(for: event, now: now)
        let newStatus = shouldAutoArchive(event, derivedStatus: derived, now: now) ? .archived : derived

        guard newStatus != event.status else { return false }
        event.status = newStatus
        event.updatedAt = now
        return true
    }

    /// Sweep reconciliation for list queries — docs/04-event-types.md "Reconciliation" point 2.
    /// Call on app launch/foreground. Filters in Swift rather than via `#Predicate` on an enum
    /// property — V1's event counts are small and this avoids relying on SwiftData predicate
    /// support for Codable enum equality.
    static func sweep(context: ModelContext, now: Date = .now) {
        guard let events = try? context.fetch(FetchDescriptor<KueEvent>()) else { return }
        var changed = false
        for event in events where event.status != .archived {
            if reconcile(event, now: now) { changed = true }
        }
        if changed { try? context.save() }
    }

    private static func shouldAutoArchive(_ event: KueEvent, derivedStatus: EventStatus, now: Date) -> Bool {
        let reachedAt: Date
        switch derivedStatus {
        case .cancelled:
            reachedAt = event.cancelledAt ?? now
        case .completed:
            reachedAt = event.isManuallyCompleted ? (event.manuallyCompletedAt ?? now) : event.effectiveEndDate
        default:
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        guard let threshold = calendar.date(byAdding: .day, value: autoArchiveDays, to: reachedAt) else {
            return false
        }
        return now >= threshold
    }
}
