//
//  ReminderPreference.swift
//  Kue
//
//  See docs/25-honest-event-outcomes-and-reminders.md "H." — the configurable pre-event
//  reminder's duration. App Group `UserDefaults`, the same "avoid a SwiftData migration for a
//  small global preference" reasoning `LiveActivityPrivacyPreference` (Phase 9) and
//  `SpotlightIndexingPreference` (Phase 10) already established — this is a *global*
//  notification-timing preference, not per-event data, so it doesn't belong on `KueEvent`
//  even if a schema change were otherwise justified.
//
//  Default: 30 minutes before `startDate` — conservative in the sense that it's the shortest
//  interval still genuinely useful for "get moving," without being so far ahead (e.g. a full
//  day) that it reads as noise for most V1 event types. `nil` = Off.
//

import Foundation

struct ReminderPreference: Equatable {
    /// `nil` means the pre-event reminder is off. A `0` value is never stored — "Off" is
    /// represented as `nil`, not zero minutes.
    var preEventMinutes: Int?

    static let conservativeDefault = ReminderPreference(preEventMinutes: 30)

    /// The fixed set Settings offers — Off plus a small, useful spread. Kept short
    /// deliberately (docs/25 "H.": "a small set of useful durations").
    static let availableOptions: [Int?] = [nil, 15, 30, 60, 1440]

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let preEventMinutesKey = "reminder.preEventMinutes"
    /// Distinguishes "never set — use the default" from "explicitly set to Off" (which must
    /// persist as `nil`, not silently revert to the default on next read).
    private static let hasBeenSetKey = "reminder.preEventMinutes.hasBeenSet"

    static var current: ReminderPreference {
        guard defaults.bool(forKey: hasBeenSetKey) else { return conservativeDefault }
        let stored = defaults.object(forKey: preEventMinutesKey) as? Int
        return ReminderPreference(preEventMinutes: stored)
    }

    static func setPreEventMinutes(_ minutes: Int?) {
        defaults.set(true, forKey: hasBeenSetKey)
        if let minutes {
            defaults.set(minutes, forKey: preEventMinutesKey)
        } else {
            defaults.removeObject(forKey: preEventMinutesKey)
        }
    }

    static func displayName(forMinutes minutes: Int?) -> String {
        switch minutes {
        case nil: return "Off"
        case 15: return "15 minutes before"
        case 30: return "30 minutes before"
        case 60: return "1 hour before"
        case 1440: return "1 day before"
        case .some(let value): return "\(value) minutes before"
        }
    }
}
