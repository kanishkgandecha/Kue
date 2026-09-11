//
//  NotificationQuietHoursPolicyTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Quiet hours": start/end, overnight
//  ranges, enabled weekdays, event-start/time-sensitive carve-outs, deterministic move-not-drop.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct NotificationQuietHoursPolicyTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2024-01-01 00:00:00 UTC is a Monday.
    private func date(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00 UTC, Monday
        return base.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
    }

    @Test func disabledQuietHoursAlwaysDeliversAtRequestedTime() {
        let decision = NotificationQuietHoursPolicy.decision(
            for: date(hour: 23), quietHours: .disabled, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar
        )
        #expect(decision == .deliverAtRequestedTime)
    }

    @Test func sameDayWindowMovesDeliveryToTheWindowsEnd() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 13 * 60 // 1 PM
        quiet.endMinute = 17 * 60 // 5 PM
        quiet.allowEventStartThrough = false

        let requested = date(hour: 14) // 2 PM — inside the window
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .moveToQuietHoursEnd(date(hour: 17)))
    }

    @Test func overnightWindowMovesAnEveningRequestToNextMorning() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60 // 10 PM
        quiet.endMinute = 7 * 60 // 7 AM
        quiet.allowEventStartThrough = false

        let requested = date(hour: 23) // 11 PM
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .moveToQuietHoursEnd(date(hour: 7, dayOffset: 1)))
    }

    @Test func overnightWindowMovesAnEarlyMorningRequestToTheSameMorningEnd() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60
        quiet.allowEventStartThrough = false

        let requested = date(hour: 3) // 3 AM — still inside last night's window
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .moveToQuietHoursEnd(date(hour: 7)))
    }

    @Test func outsideTheWindowDeliversAtRequestedTime() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60

        let requested = date(hour: 12) // noon — outside the overnight window
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .deliverAtRequestedTime)
    }

    @Test func eventStartCarveOutBypassesQuietHoursWhenAllowed() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60
        quiet.allowEventStartThrough = true

        let requested = date(hour: 23)
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: true, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .deliverAtRequestedTime)
    }

    @Test func timeSensitiveCarveOutBypassesQuietHoursWhenAllowed() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60
        quiet.allowTimeSensitiveThrough = true

        let requested = date(hour: 23)
        let decision = NotificationQuietHoursPolicy.decision(for: requested, quietHours: quiet, isEventStart: false, isTimeSensitive: true, calendar: utcCalendar)
        #expect(decision == .deliverAtRequestedTime)
    }

    @Test func aWeekdayNotInEnabledWeekdaysNeverAppliesQuietHours() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60
        quiet.enabledWeekdays = [1, 7] // Sunday/Saturday only

        let mondayNight = date(hour: 23) // Monday, per this file's own reference date
        let decision = NotificationQuietHoursPolicy.decision(for: mondayNight, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .deliverAtRequestedTime)
    }

    @Test func weekendOnlyQuietHoursAppliesOnAnEnabledWeekendDay() {
        var quiet = NotificationQuietHours.disabled
        quiet.isEnabled = true
        quiet.startMinute = 22 * 60
        quiet.endMinute = 7 * 60
        quiet.allowEventStartThrough = false
        quiet.enabledWeekdays = [1, 7] // Sunday/Saturday

        let saturdayNight = date(hour: 23, dayOffset: 5) // Monday + 5 days = Saturday
        let decision = NotificationQuietHoursPolicy.decision(for: saturdayNight, quietHours: quiet, isEventStart: false, isTimeSensitive: false, calendar: utcCalendar)
        #expect(decision == .moveToQuietHoursEnd(date(hour: 7, dayOffset: 6)))
    }
}
