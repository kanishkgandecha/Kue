//
//  SpotlightIndexingPreference.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "L." — whether Spotlight indexing is
//  enabled at all, surfaced in Settings. App Group `UserDefaults`, same "avoid a SwiftData
//  migration for one boolean" reasoning `LiveActivityPrivacyPreference` (Phase 9) already
//  established — reachable from the app without a new `@Model` field or migration stage.
//

import Foundation

enum SpotlightIndexingPreference {
    /// Default on — Spotlight is a discoverability feature users generally expect once an app
    /// supports it, and the indexed field list (docs/24 "Privacy matrix") is already
    /// conservative, so there's no default-off privacy reason the way Live Activity's next-task
    /// title had.
    static let defaultEnabled = true

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let enabledKey = "spotlight.indexingEnabled"

    static var isEnabled: Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: enabledKey)
    }
}
