//
//  CloudStatisticsPreference.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Preference and consent." The explicit Cloud Statistics on/off
//  setting — App Group `UserDefaults`-backed, the exact same established pattern
//  `SyncPreference.swift` already uses. **Default off** (requirement F) — cloud statistics are
//  strictly opt-in, never silently turned on merely because an account is signed in.
//
//  Deliberately independent of `SyncPreference` — a signed-in user may want event sync without
//  ever uploading productivity statistics, or vice versa (requirement A: "account creation and
//  cloud statistics remain optional," each its own decision).
//

import Foundation

nonisolated struct CloudStatisticsPreference: Equatable {
    var isEnabled: Bool

    static let disabled = CloudStatisticsPreference(isEnabled: false)

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }
    private static let isEnabledKey = "cloudStatistics.isEnabled"

    static var current: CloudStatisticsPreference {
        CloudStatisticsPreference(isEnabled: defaults.bool(forKey: isEnabledKey))
    }

    static func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: isEnabledKey)
    }
}
