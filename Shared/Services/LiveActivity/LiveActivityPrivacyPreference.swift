//
//  LiveActivityPrivacyPreference.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "I. Privacy" — deliberately *not* a new
//  `UserPreference` (`@Model`) stored property: that would require a new `VersionedSchema`
//  and migration stage for two booleans (docs/15-schema-migrations.md), which this phase's
//  own instruction says to avoid unless genuinely necessary. App Group `UserDefaults` is the
//  same sharing mechanism the shared SwiftData store itself already depends on
//  (`ModelContainerFactory.appGroupIdentifier`), reachable from the app, the widget
//  extension, and the Share Extension alike, with no schema at all.
//
//  Defaults are conservative for an ambient-visible Lock Screen surface, not for a Home
//  Screen widget: the event *title* defaults to shown (without it a Live Activity is close
//  to useless, and every existing Kue widget already shows titles unconditionally), but the
//  *next task's own title* — much more likely to be specific/sensitive ("Call the lawyer,"
//  "Pick up prescription") — defaults to hidden until the user opts in.
//

import Foundation

struct LiveActivityPrivacyPreference: Equatable {
    var showTitle: Bool
    var showNextTask: Bool

    static let conservativeDefault = LiveActivityPrivacyPreference(showTitle: true, showNextTask: false)

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let showTitleKey = "liveActivity.showTitle"
    private static let showNextTaskKey = "liveActivity.showNextTask"

    /// Reads the live preference from App Group `UserDefaults` every call — cheap (no disk
    /// I/O beyond what `UserDefaults` already caches in memory), and avoids a second stale-
    /// cache problem the way an uncached `ModelContainer` construction was (docs/22's own
    /// disproven-hypothesis note).
    static var current: LiveActivityPrivacyPreference {
        LiveActivityPrivacyPreference(
            showTitle: defaults.object(forKey: showTitleKey) as? Bool ?? conservativeDefault.showTitle,
            showNextTask: defaults.object(forKey: showNextTaskKey) as? Bool ?? conservativeDefault.showNextTask
        )
    }

    static func setShowTitle(_ value: Bool) {
        defaults.set(value, forKey: showTitleKey)
    }

    static func setShowNextTask(_ value: Bool) {
        defaults.set(value, forKey: showNextTaskKey)
    }
}
