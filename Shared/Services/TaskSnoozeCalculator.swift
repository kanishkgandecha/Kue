//
//  TaskSnoozeCalculator.swift
//  Kue
//
//  See docs/07-widget-engine.md "SnoozeTaskIntent" — the exact clamp contract. Pure
//  Foundation, no SwiftData/WidgetKit — used both by `WidgetContentService`/widget rendering
//  (to decide whether the snooze button should even appear) and by `SnoozeTaskIntent`'s
//  `perform()` (to compute the actual new due date), so the "is snoozing possible right now"
//  question is answered identically in both places by construction, not by two independently
//  maintained checks.
//

import Foundation

enum TaskSnoozeCalculator {
    /// `now + minimumLeadTime >= event.startDate - minimumLeadTime` — the event is imminent
    /// enough that no future due date could fit before it. When this is true, the doc says
    /// the snooze button must be *hidden*, not shown disabled.
    static func isSnoozeAvailable(eventStartDate: Date, now: Date = .now) -> Bool {
        let lower = now.addingTimeInterval(SchedulingEngine.minimumLeadTime)
        let upper = eventStartDate.addingTimeInterval(-SchedulingEngine.minimumLeadTime)
        return lower < upper
    }

    /// `clamp(dueDate + 1 day, lower: now + minimumLeadTime, upper: event.startDate -
    /// minimumLeadTime)`, computed with the event's own timezone (docs/05-scheduling-
    /// engine.md date-math rules — `Calendar.date(byAdding:to:)`, never raw `TimeInterval`
    /// arithmetic, so the "+1 day" step lands on the correct wall-clock time across a DST
    /// boundary). Returns `nil` when the interval is empty — see `isSnoozeAvailable` — so a
    /// button that should have been hidden can't silently no-op into a wrong date instead.
    static func snoozedDueDate(
        currentDueDate: Date,
        eventStartDate: Date,
        timeZoneIdentifier: String,
        now: Date = .now
    ) -> Date? {
        guard isSnoozeAvailable(eventStartDate: eventStartDate, now: now) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        guard let proposed = calendar.date(byAdding: .day, value: 1, to: currentDueDate) else { return nil }

        let lower = now.addingTimeInterval(SchedulingEngine.minimumLeadTime)
        let upper = eventStartDate.addingTimeInterval(-SchedulingEngine.minimumLeadTime)
        return min(max(proposed, lower), upper)
    }

    /// docs/07-widget-engine.md: "When the clamp applies, `offsetLabel` reflects the actual
    /// new due date... rather than a stale '+1 day' label." Reuses
    /// `SchedulingEngine.offsetLabel(_:)` — the same "N days/hours/minutes before" phrasing
    /// every other task already uses — rather than inventing new copy.
    static func offsetLabel(newDueDate: Date, eventStartDate: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.day, .hour, .minute], from: newDueDate, to: eventStartDate)
        return SchedulingEngine.offsetLabel(components)
    }
}
