//
//  SmartPlanningPreferences.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "G. Preferences". App Group `UserDefaults`, one JSON-encoded
//  struct — the exact `NotificationGlobalPreferences.swift` precedent (see that file's own
//  header) for "avoid a SwiftData migration for a global preference," reused verbatim rather
//  than re-argued. New fields are `Optional` with an `effective*` accessor wherever a future
//  addition needs to decode cleanly against an already-stored pre-this-field JSON blob.
//
//  **Per-device, not synchronized** — docs/36 "Persistence and synchronization": every field
//  here is a planning *preference*, never event/task content, and none of it is required for
//  Smart Planning to work correctly on a second device (the engine recomputes everything from
//  that device's own already-synced events/tasks on every launch). Syncing it would mean a
//  first Supabase table and RLS policy for a feature the spec explicitly says to keep
//  deterministic and privacy-first wherever possible (docs/36 "Privacy") — deferred, not
//  fabricated need (YAGNI). Documented explicitly, matching the same decision this codebase
//  already made for `NotificationGlobalPreferences`/`CloudStatisticsPreference`'s own settings
//  half in Phases 6/7.
//

import Foundation

/// docs/36 "Planning intensity": "understandable options... must affect thresholds — not
/// fabricate additional recommendations." Each case only ever scales the numeric thresholds
/// `SmartPlanningEngine` already computes from real data; see that file's own use of
/// `overdueGraceHours`/`workloadMultiplier`/`riskLeadDays` below.
nonisolated enum PlanningIntensity: String, Codable, CaseIterable, Equatable {
    case gentle, balanced, ambitious

    var displayName: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        case .ambitious: return "Ambitious"
        }
    }

    var displayDescription: String {
        switch self {
        case .gentle: return "Fewer suggestions, higher bar before something is flagged."
        case .balanced: return "A steady, moderate pace of suggestions."
        case .ambitious: return "Earlier warnings and more proactive preparation suggestions."
        }
    }

    /// Multiplies the daily-workload ceiling before "Reduce Today's Load" fires — ambitious
    /// users are comfortable with a fuller day before the planner calls it overloaded.
    var workloadMultiplier: Double {
        switch self {
        case .gentle: return 0.75
        case .balanced: return 1.0
        case .ambitious: return 1.35
        }
    }

    /// How many days before an event "Prepare for Upcoming Event"/"Schedule Preparation"
    /// starts looking ahead — gentle waits until things are closer and clearer; ambitious
    /// flags risk earlier.
    var riskLeadDays: Int {
        switch self {
        case .gentle: return 2
        case .balanced: return 4
        case .ambitious: return 7
        }
    }

    /// Grace period before an incomplete task actually counts as "overdue" for scoring
    /// purposes — avoids flagging something 10 minutes past due at `gentle`.
    var overdueGraceHours: Double {
        switch self {
        case .gentle: return 12
        case .balanced: return 2
        case .ambitious: return 0
        }
    }
}

nonisolated struct SmartPlanningPreferences: Codable, Equatable {
    var masterEnabled: Bool
    /// Minutes since midnight, device-local wall clock — same convention
    /// `NotificationQuietHours`/`allDayPreferredMinuteOfDay` already use.
    var planningWindowStartMinute: Int
    var planningWindowEndMinute: Int
    /// A count, not a duration — see `SmartPlanningEngine`'s own header for why the engine
    /// never fabricates per-task minute estimates the data model doesn't actually have.
    /// Represents "how many not-yet-complete prep tasks feel like a full day" at `balanced`.
    var maxDailyTaskLoad: Int
    var defaultFocusBlockMinutes: Int
    /// `Calendar.Component.weekday` raw values (1 = Sunday ... 7 = Saturday) — same
    /// convention `NotificationQuietHours.enabledWeekdays` uses.
    var workingWeekdays: Set<Int>
    var intensity: PlanningIntensity
    var considerCalendarAvailability: Bool
    var useLocalStatistics: Bool

    static let conservativeDefault = SmartPlanningPreferences(
        masterEnabled: true,
        planningWindowStartMinute: 9 * 60,
        planningWindowEndMinute: 18 * 60,
        maxDailyTaskLoad: 5,
        defaultFocusBlockMinutes: 45,
        workingWeekdays: Set(2...6), // Monday...Friday
        intensity: .balanced,
        considerCalendarAvailability: true,
        useLocalStatistics: true
    )

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let storageKey = "smartPlanning.preferences.v1"

    static var current: SmartPlanningPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SmartPlanningPreferences.self, from: data) else {
            return conservativeDefault
        }
        return decoded
    }

    static func save(_ preferences: SmartPlanningPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
