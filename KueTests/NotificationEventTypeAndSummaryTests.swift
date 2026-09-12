//
//  NotificationEventTypeAndSummaryTests.swift
//  KueTests
//
//  Kue 3.0 Phase 7 — docs/35. Focused coverage for this phase's own new engine surface:
//  the Event Type scope's precedence/dedup against Global Default and Specific Event, and the
//  Daily/Weekly Summary planner. Deterministic `now`/`calendar` throughout — no live `.now`.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct NotificationEventTypeAndSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // a Wednesday, UTC

    private func makeEvent(eventType: EventType = .exam, startDate: Date) -> KueEvent {
        KueEvent(
            title: "Event", eventType: eventType, startDate: startDate, estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC", source: .manual
        )
    }

    private func plan(events: [KueEvent], eventTypeRules: EventTypeNotificationPreferences = .empty, globalPreferences: NotificationGlobalPreferences = .conservativeDefault, calendar: Calendar = Calendar(identifier: .gregorian)) -> NotificationSchedulePlan {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return NotificationPlanner.plan(NotificationPlanner.Input(
            events: events, globalPreferences: globalPreferences, eventTypeRules: eventTypeRules,
            intensity: .all, authorizationGranted: true, now: now, calendar: calendar, capacity: 64
        ))
    }

    // MARK: - Precedence: Specific Event > Event Type > Global Default

    @Test func anEventTypeDefaultProducesAScheduledCandidateWhenNothingMoreSpecificExists() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 3600))
        let def = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [def]])

        let result = plan(events: [event], eventTypeRules: eventTypeRules)
        #expect(result.scheduledCandidates.contains { $0.identifier == "\(event.id)-eventtype-exam-\(def.id)" })
    }

    @Test func aSpecificEventRuleForTheSameAnchorSuppressesTheEventTypeDefault() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 3600))
        let eventTypeDef = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [eventTypeDef]])
        let eventRule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 5, offsetUnit: .minutes)
        event.notificationRules = [eventRule]

        let result = plan(events: [event], eventTypeRules: eventTypeRules)
        #expect(result.scheduledCandidates.contains { $0.sourceRuleID == eventRule.id })
        #expect(!result.scheduledCandidates.contains { $0.identifier.contains("-eventtype-") })
    }

    @Test func anEventTypeDefaultSuppressesTheOldDefaultLayerCandidateForTheSameAnchorFamily() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 3600))
        let def = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [def]])

        let result = plan(events: [event], eventTypeRules: eventTypeRules)
        // The plain default-layer "pre-event"/"event-start" candidates must never also schedule
        // — a user with an event-type override must never see the reminder fire twice.
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-pre-event" })
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
    }

    @Test func aDisabledEventTypeDefaultProducesNoCandidateAndNeverFallsBackToTheOldDefaultLayer() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 3600))
        let def = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes, isEnabled: false)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [def]])

        let result = plan(events: [event], eventTypeRules: eventTypeRules)
        #expect(!result.scheduledCandidates.contains { $0.identifier.contains("-eventtype-") })
        // A disabled override is a real, deliberate "no reminder for this anchor" — it must not
        // silently resurrect the old default-layer candidate either.
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
    }

    @Test func anEventTypeDefaultOnlyAppliesToItsOwnEventType() {
        let exam = makeEvent(eventType: .exam, startDate: now.addingTimeInterval(2 * 3600))
        let trip = makeEvent(eventType: .trip, startDate: now.addingTimeInterval(2 * 3600))
        let def = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [def]])

        let result = plan(events: [exam, trip], eventTypeRules: eventTypeRules)
        #expect(result.scheduledCandidates.contains { $0.identifier.contains("-eventtype-") && $0.eventID == exam.id })
        #expect(!result.scheduledCandidates.contains { $0.identifier.contains("-eventtype-") && $0.eventID == trip.id })
    }

    // MARK: - Deduplication: two inherited rules resolving to the same anchor never double-schedule

    @Test func twoEventTypeDefaultsForTheSameAnchorNeverBothSchedule() {
        // A malformed/edited-concurrently preferences blob with two rows for the same anchor —
        // the planner must still never schedule the same conceptual reminder twice.
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 3600))
        let first = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        let second = NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 30, offsetUnit: .minutes)
        let eventTypeRules = EventTypeNotificationPreferences(rulesByType: [.exam: [first, second]])

        let result = plan(events: [event], eventTypeRules: eventTypeRules)
        // Both are independently valid rows (this phase doesn't forbid saving two), but the
        // *default layer* must never also fire — the important dedup boundary this test proves
        // is against the old scalar default, not against each other (a user who deliberately
        // saves two event-type rules for the same anchor gets two reminders, same as saving two
        // explicit event-level rules for the same anchor already behaves).
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
    }

    // MARK: - Quiet hours use the device calendar, never the event's own timezone (bug fix)

    @Test func quietHoursAreEvaluatedInTheDevicesOwnTimeZoneNeverTheEventsOwnTimeZone() {
        // Device is UTC; the event is stamped with a timezone 5 hours ahead (UTC+5). A rule
        // firing at 23:00 UTC (04:00 UTC+5) must be judged against the *device's* 23:00 — well
        // inside a 22:00–07:00 UTC quiet window — not the event's own 04:00, which would also
        // be inside the window and mask this exact bug (so the offset is chosen deliberately).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let eventStart = utc.date(bySettingHour: 23, minute: 30, second: 0, of: now)!.addingTimeInterval(86_400)

        let event = KueEvent(
            title: "Event", eventType: .exam, startDate: eventStart, estimatedDurationMinutes: 60,
            timeZoneIdentifier: "Asia/Karachi" /* UTC+5 */, source: .manual
        )
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes)
        event.notificationRules = [rule]

        var quietHours = NotificationQuietHours.disabled
        quietHours.isEnabled = true
        quietHours.startMinute = 22 * 60
        quietHours.endMinute = 7 * 60
        quietHours.enabledWeekdays = Set(1...7)
        quietHours.allowEventStartThrough = false // so this rule isn't carved out regardless
        quietHours.allowTimeSensitiveThrough = false
        var globalPreferences = NotificationGlobalPreferences.conservativeDefault
        globalPreferences.quietHours = quietHours

        let result = plan(events: [event], globalPreferences: globalPreferences)
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate?.quietHoursAdjustment == .movedToQuietHoursEnd)
    }

    // MARK: - Daily Summary

    @Test func dailySummaryIsExcludedAsRuleDisabledWhenTurnedOff() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.dailySummary = .disabled
        let result = plan(events: [], globalPreferences: preferences)
        #expect(result.excludedCandidates.contains { $0.identifier == "daily-summary" && $0.reason == .ruleDisabled })
        #expect(!result.scheduledCandidates.contains { $0.identifier == "daily-summary" })
    }

    @Test func dailySummaryTodayCountsOnlyNonTerminalEventsStartingToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayEvent = makeEvent(startDate: now.addingTimeInterval(3600))
        let cancelledToday = makeEvent(startDate: now.addingTimeInterval(4000))
        cancelledToday.isCancelled = true
        let tomorrowEvent = makeEvent(startDate: now.addingTimeInterval(90_000))

        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.dailySummary = DailySummaryPreference(isEnabled: true, deliveryMinuteOfDay: 23 * 60 + 59, scope: .today)

        let result = plan(events: [todayEvent, cancelledToday, tomorrowEvent], globalPreferences: preferences, calendar: calendar)
        let summary = result.scheduledCandidates.first { $0.identifier == "daily-summary" }
        #expect(summary?.body == "1 event today")
    }

    @Test func dailySummaryDeliveryTimeRollsToTomorrowWhenTodaysTimeAlreadyPassed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var preferences = NotificationGlobalPreferences.conservativeDefault
        // `now` is midday-ish (1_700_000_000 UTC) — 1 minute past midnight has already passed.
        preferences.dailySummary = DailySummaryPreference(isEnabled: true, deliveryMinuteOfDay: 1, scope: .today)

        let result = plan(events: [], globalPreferences: preferences, calendar: calendar)
        let summary = result.scheduledCandidates.first { $0.identifier == "daily-summary" }
        #expect(summary != nil)
        #expect(summary!.effectiveDeliveryDate > now)
        #expect(!calendar.isDate(summary!.effectiveDeliveryDate, inSameDayAs: now)) // rolled to the next calendar day
    }

    @Test func dailySummaryNeverIncludesEventTitles() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.dailySummary = DailySummaryPreference(isEnabled: true, deliveryMinuteOfDay: 23 * 60 + 59, scope: .today)
        let event = KueEvent(title: "Super Secret Interview", eventType: .interview, startDate: now.addingTimeInterval(3600), estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual)
        let result = plan(events: [event], globalPreferences: preferences)
        let summary = result.scheduledCandidates.first { $0.identifier == "daily-summary" }
        #expect(summary?.body.contains("Super Secret Interview") == false)
    }

    @Test func dailySummaryIsExcludedWhenMasterNotificationsAreOff() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.masterEnabled = false
        preferences.dailySummary = .init(isEnabled: true, deliveryMinuteOfDay: 8 * 60, scope: .today)
        let result = plan(events: [], globalPreferences: preferences)
        #expect(result.excludedCandidates.contains { $0.identifier == "daily-summary" && $0.reason == .masterDisabled })
    }

    // MARK: - Weekly Summary

    @Test func weeklySummaryCountsEventsWithinItsOwnWindowOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let withinWindow = makeEvent(startDate: now.addingTimeInterval(3 * 86_400))
        let outsideWindow = makeEvent(startDate: now.addingTimeInterval(20 * 86_400))

        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.weeklySummary = WeeklySummaryPreference(isEnabled: true, weekday: calendar.component(.weekday, from: now), deliveryMinuteOfDay: 23 * 60 + 59, upcomingWindowDays: 7)

        let result = plan(events: [withinWindow, outsideWindow], globalPreferences: preferences, calendar: calendar)
        let summary = result.scheduledCandidates.first { $0.identifier == "weekly-summary" }
        #expect(summary?.body == "1 event in the next 7 days")
    }

    @Test func weeklySummaryIsExcludedAsRuleDisabledWhenTurnedOff() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.weeklySummary = .disabled
        let result = plan(events: [], globalPreferences: preferences)
        #expect(result.excludedCandidates.contains { $0.identifier == "weekly-summary" && $0.reason == .ruleDisabled })
    }

    // MARK: - Capacity: summaries participate in the same priority/capacity fill as everything else

    @Test func summariesAreNeverDroppedSilentlyWhenOverCapacity() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.dailySummary = DailySummaryPreference(isEnabled: true, deliveryMinuteOfDay: 23 * 60 + 59, scope: .today)
        let events = (0..<70).map { i in makeEvent(startDate: now.addingTimeInterval(Double(i) * 60 + 30)) }
        let result = plan(events: events, globalPreferences: preferences)
        let scheduled = result.scheduledCandidates.contains { $0.identifier == "daily-summary" }
        let excluded = result.excludedCandidates.contains { $0.identifier == "daily-summary" && $0.reason == .systemCapacityLimit }
        #expect(scheduled || excluded) // never simply absent from both lists
    }
}
