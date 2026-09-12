//
//  NotificationGlobalPreferences.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Global settings". App Group
//  `UserDefaults`, the same "avoid a SwiftData migration for a global preference" precedent
//  `LiveActivityPrivacyPreference`/`ReminderPreference`/`SpotlightIndexingPreference` already
//  establish — none of this is per-event *content*, so it doesn't belong in the new
//  `NotificationRule` table either. One JSON-encoded struct rather than one `UserDefaults` key
//  per field, so adding a field later never needs its own migration.
//
//  **Per-device, not synchronized** (docs/31 "Per-device behavior"): App Group `UserDefaults`
//  is already local to *this install* on *this device* — nothing in Kue syncs `UserDefaults`
//  across a person's devices (Phase 11's `CKSyncEngine` only mirrors the SwiftData store; this
//  phase adds no backend at all). So `deliverOnThisDevice` living in the same struct as every
//  other preference here already satisfies "stored locally per device" — no separate mechanism
//  needed. Turning it off is read by `NotificationPlanner` as "exclude every candidate for this
//  device" (docs/31's own required typed reason, `.disabledOnThisDevice`); turning it back on
//  deterministically rebuilds the schedule the next time `NotificationEngine.reschedule` runs
//  (foreground, any mutation, or an explicit "Reschedule" action), the same self-healing pass
//  every other preference change already goes through.
//
//  **Migration/continuity** (docs/31 "Migration"): the first time this is ever read on a build
//  that predates this phase, `current` seeds itself from `ReminderPreference.current`/
//  `UserPreference.notificationIntensity` so a user's existing reminder behavior doesn't
//  silently change the moment this phase ships — see `seedFromLegacyPreferencesIfNeeded()`.
//

import Foundation

/// docs/31 "Privacy": the three preview levels — never a per-notification choice, a global one.
enum NotificationPreviewPrivacy: String, Codable, CaseIterable {
    /// Real event and task names.
    case full
    /// The real event name; task-derived copy stays generic ("A task is due").
    case eventOnly
    /// A generic "Kue Reminder" — no event or task identity at all.
    case `private`
}

/// docs/31 "Quiet hours". Overnight ranges are expressed the same way a person would say them —
/// `end` earlier in the clock than `start` means "wraps past midnight," not "invalid."
/// `nonisolated` so its `static let disabled` is usable from `NotificationGlobalPreferences
/// .conservativeDefault` (itself `nonisolated`) under this module's `@MainActor`-by-default
/// isolation — same reason `NotificationCandidate`/`NotificationSchedulePlan` are `nonisolated`.
nonisolated struct NotificationQuietHours: Codable, Equatable {
    var isEnabled: Bool
    /// Minutes since midnight, local to whatever calendar the planner is given (docs/31: quiet
    /// hours are a wall-clock, device-local concept, not pinned to any event's own timezone).
    var startMinute: Int
    var endMinute: Int
    /// `Calendar.Component.weekday` raw values (1 = Sunday ... 7 = Saturday) quiet hours apply
    /// on. Empty means "never" even if `isEnabled` — `enabledWeekdays` is the actual gate.
    var enabledWeekdays: Set<Int>
    var allowEventStartThrough: Bool
    var allowTimeSensitiveThrough: Bool

    static let disabled = NotificationQuietHours(
        isEnabled: false, startMinute: 22 * 60, endMinute: 7 * 60,
        enabledWeekdays: Set(1...7), allowEventStartThrough: true, allowTimeSensitiveThrough: true
    )
}

/// Kue 3.0 Phase 7 — docs/35 "Summaries." A privacy-safe, device-scheduled daily digest —
/// never a live per-event `NotificationRule` (there is no single event to anchor it to).
/// `Optional` on `NotificationGlobalPreferences` (see this file's own migration precedent for
/// `defaultSnoozeMinutes`) so an install that predates this phase decodes its existing stored
/// JSON cleanly — a missing key means "never configured," read as `.disabled` everywhere,
/// never a surprise new notification appearing after an update.
nonisolated struct DailySummaryPreference: Codable, Equatable {
    var isEnabled: Bool
    /// Minutes since midnight, device-local wall clock — same convention as
    /// `allDayPreferredMinuteOfDay`/`NotificationQuietHours`.
    var deliveryMinuteOfDay: Int
    var scope: DailySummaryScope

    static let disabled = DailySummaryPreference(isEnabled: false, deliveryMinuteOfDay: 8 * 60, scope: .today)
}

nonisolated enum DailySummaryScope: String, Codable, CaseIterable {
    case today
    case tomorrow
}

/// Kue 3.0 Phase 7 — docs/35 "Summaries." Same shape/reasoning as `DailySummaryPreference`.
nonisolated struct WeeklySummaryPreference: Codable, Equatable {
    var isEnabled: Bool
    /// `Calendar.Component.weekday` raw value (1 = Sunday ... 7 = Saturday) — same convention
    /// `NotificationQuietHours.enabledWeekdays` already uses.
    var weekday: Int
    var deliveryMinuteOfDay: Int
    /// How many days ahead the summary counts — a plain, disclosed integer, never a hidden
    /// "smart" window.
    var upcomingWindowDays: Int

    static let disabled = WeeklySummaryPreference(isEnabled: false, weekday: 2 /* Monday */, deliveryMinuteOfDay: 8 * 60, upcomingWindowDays: 7)
}

nonisolated struct NotificationGlobalPreferences: Codable, Equatable {
    var masterEnabled: Bool
    /// docs/31 "Rule editor": a small, useful spread, same spirit as `ReminderPreference
    /// .availableOptions` — offered as candidate "before event start" minute values in the
    /// rule editor and used to seed a brand-new event's implicit default when this phase's own
    /// per-event `NotificationRule` override system isn't otherwise engaged.
    var defaultPreEventMinutes: Int?
    var defaultOutcomeFollowUpEnabled: Bool
    /// `nil` means "at event start," matching the pre-existing `.taskDue` default behavior
    /// (before this phase, tasks only ever notified exactly at their own `dueDate`).
    var defaultTaskReminderMinutesBeforeDue: Int?
    /// Minutes since midnight — docs/31 "Rule editor": "explain whether an all-day offset is
    /// based on midnight, a configured preferred time" — this *is* that configured time,
    /// replacing the previously-hardcoded 9:00 AM in `NotificationCandidateBuilder`.
    var allDayPreferredMinuteOfDay: Int
    var quietHours: NotificationQuietHours
    /// docs/31 "Weekend behavior" — `false` mutes non-essential (tier ≥ 1) notifications on
    /// `enabledWeekdays` outside `quietHours`' own scope; event-start/outcome-follow-up still
    /// always fire, matching quiet hours' own "allow event-start through" spirit.
    var nonEssentialNotificationsOnWeekends: Bool
    var soundPreference: NotificationSoundOption
    var badgeEnabled: Bool
    var previewPrivacy: NotificationPreviewPrivacy
    /// docs/31 "Grouping preference" — maps to `UNMutableNotificationContent.threadIdentifier`;
    /// `true` groups every Kue notification for the same event into one thread.
    var groupNotificationsByEvent: Bool
    var timeSensitiveEnabled: Bool
    /// docs/31 "Per-device behavior" — see this file's own header for why this lives here
    /// rather than a separate mechanism.
    var deliverOnThisDevice: Bool
    /// Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze": what a rule's own
    /// "Use global default" snooze picker option resolves to. `Int?`, not a plain `Int`, so an
    /// already-encoded pre-completion-pass `UserDefaults` blob — which has no such key at all —
    /// still decodes cleanly (Swift's synthesized `Decodable` treats a missing key on an
    /// `Optional` stored property as `nil`, not a decode failure); every call site that reads
    /// this falls back to a fixed 10 minutes when it's `nil`, so old and new installs behave
    /// identically either way.
    var defaultSnoozeMinutes: Int?
    /// Kue 3.0 Phase 7 — docs/35 "Summaries." `Optional`, not defaulted, for the exact same
    /// old-JSON-decoding reason as `defaultSnoozeMinutes` above; every read site uses
    /// `effectiveDailySummary`/`effectiveWeeklySummary` below rather than the raw optional.
    var dailySummary: DailySummaryPreference?
    var weeklySummary: WeeklySummaryPreference?

    var effectiveDailySummary: DailySummaryPreference { dailySummary ?? .disabled }
    var effectiveWeeklySummary: WeeklySummaryPreference { weeklySummary ?? .disabled }

    /// docs/31 "Migration": what a brand-new install (or a pre-Phase-3 install on its first
    /// read) gets — deliberately reproduces `ReminderPreference.conservativeDefault`/
    /// `NotificationIntensity.standard`'s existing behavior exactly, not a fresh opinion.
    static let conservativeDefault = NotificationGlobalPreferences(
        masterEnabled: true,
        defaultPreEventMinutes: 30,
        defaultOutcomeFollowUpEnabled: true,
        defaultTaskReminderMinutesBeforeDue: nil,
        allDayPreferredMinuteOfDay: 9 * 60,
        quietHours: .disabled,
        nonEssentialNotificationsOnWeekends: true,
        soundPreference: .defaultSound,
        badgeEnabled: true,
        previewPrivacy: .full,
        groupNotificationsByEvent: true,
        timeSensitiveEnabled: false,
        deliverOnThisDevice: true,
        defaultSnoozeMinutes: 10,
        dailySummary: nil,
        weeklySummary: nil
    )

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let storageKey = "notificationStudio.globalPreferences.v1"

    static var current: NotificationGlobalPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(NotificationGlobalPreferences.self, from: data) else {
            return seededFromLegacyPreferences()
        }
        return decoded
    }

    static func save(_ preferences: NotificationGlobalPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// docs/31 "Migration" — called the first time `current` finds nothing stored yet. Reads
    /// (never writes) the pre-Phase-3 preferences so an upgrading install's *behavior* is
    /// unchanged until the user actually opens Notification Studio and changes something —
    /// at which point `save` persists a real `NotificationGlobalPreferences` going forward and
    /// this function is never consulted again for this install. `ReminderPreference`/
    /// `UserPreference.notificationIntensity` are left exactly as they were — nothing here
    /// deletes or migrates them away, so a hypothetical rollback loses nothing either.
    private static func seededFromLegacyPreferences() -> NotificationGlobalPreferences {
        var seeded = conservativeDefault
        seeded.defaultPreEventMinutes = ReminderPreference.current.preEventMinutes
        return seeded
    }
}
