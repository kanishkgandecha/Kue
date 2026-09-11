//
//  NotificationQuietHoursPolicy.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Quiet hours". Pure date math, no
//  SwiftData/UserDefaults reads — `calendar` is passed in explicitly so DST and timezone
//  behavior are exactly what the caller's own `Calendar` produces, never a hidden `.current`.
//

import Foundation

enum NotificationQuietHoursDecision: Equatable {
    case deliverAtRequestedTime
    case moveToQuietHoursEnd(Date)
    case suppress
}

enum NotificationQuietHoursPolicy {
    /// `isTimeSensitive`/`isEventStart` are the two carve-outs docs/31 names explicitly
    /// ("Allow event-start notifications through quiet hours," "Allow time-sensitive
    /// notifications when permitted") — checked before quiet hours apply at all.
    static func decision(
        for date: Date,
        quietHours: NotificationQuietHours,
        isEventStart: Bool,
        isTimeSensitive: Bool,
        calendar: Calendar
    ) -> NotificationQuietHoursDecision {
        guard quietHours.isEnabled else { return .deliverAtRequestedTime }
        if isEventStart && quietHours.allowEventStartThrough { return .deliverAtRequestedTime }
        if isTimeSensitive && quietHours.allowTimeSensitiveThrough { return .deliverAtRequestedTime }

        let weekday = calendar.component(.weekday, from: date)
        guard quietHours.enabledWeekdays.contains(weekday) else { return .deliverAtRequestedTime }
        guard isWithinQuietWindow(date, quietHours: quietHours, calendar: calendar) else { return .deliverAtRequestedTime }

        // Deterministic policy: quiet hours *move* delivery to the window's end, never
        // silently drop it — docs/31 is explicit that suppression is a distinct, separate
        // decision from adjustment. This planner always moves (never suppresses) once inside
        // the window; a caller that wants outright suppression for a specific rule expresses
        // that as `isEnabled = false` on the rule itself, not through quiet hours.
        guard let endDate = quietHoursEndDate(after: date, quietHours: quietHours, calendar: calendar) else {
            return .deliverAtRequestedTime // couldn't resolve a window end — fail open, never drop silently
        }
        return .moveToQuietHoursEnd(endDate)
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func isWithinQuietWindow(_ date: Date, quietHours: NotificationQuietHours, calendar: Calendar) -> Bool {
        let minute = minuteOfDay(date, calendar: calendar)
        if quietHours.startMinute == quietHours.endMinute { return false } // a zero-length window is never "quiet"
        if quietHours.startMinute < quietHours.endMinute {
            // Same-day window, e.g. 13:00–17:00.
            return minute >= quietHours.startMinute && minute < quietHours.endMinute
        }
        // Overnight window, e.g. 22:00–07:00 — "quiet" is everything from start to midnight,
        // plus everything from midnight to end.
        return minute >= quietHours.startMinute || minute < quietHours.endMinute
    }

    /// The next wall-clock instant at `endMinute`, on the correct calendar day for whichever
    /// side of an overnight window `date` currently falls on.
    private static func quietHoursEndDate(after date: Date, quietHours: NotificationQuietHours, calendar: Calendar) -> Date? {
        let endHour = quietHours.endMinute / 60
        let endMinuteComponent = quietHours.endMinute % 60
        let sameDayEnd = calendar.date(bySettingHour: endHour, minute: endMinuteComponent, second: 0, of: date)
        guard let sameDayEnd else { return nil }
        if sameDayEnd > date { return sameDayEnd }
        // The window's end already passed today's clock time (an overnight window whose end
        // is tomorrow morning) — roll forward one calendar day.
        return calendar.date(byAdding: .day, value: 1, to: sameDayEnd)
    }
}
