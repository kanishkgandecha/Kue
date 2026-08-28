//
//  SyncPreference.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "F." The explicit iCloud Sync on/off setting. App Group
//  `UserDefaults`-backed, the same established pattern `ReminderPreference`/
//  `LiveActivityPrivacyPreference`/`SpotlightIndexingPreference` already use for a device-
//  scoped preference that needs no SwiftData schema change. **Conservative default for
//  existing installations** (docs/26 "F."): `isEnabled` defaults to `false` — sync is strictly
//  opt-in, never silently turned on for someone who's been using local-only Kue.
//

import Foundation

nonisolated struct SyncPreference: Equatable {
    var isEnabled: Bool

    static let disabled = SyncPreference(isEnabled: false)

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }
    private static let isEnabledKey = "sync.isEnabled"

    static var current: SyncPreference {
        SyncPreference(isEnabled: defaults.bool(forKey: isEnabledKey))
    }

    static func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: isEnabledKey)
    }
}
