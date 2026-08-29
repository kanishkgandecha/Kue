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
        #if KUE_PERSONAL_BUILD
        // Kue 2.0 Phase 12 — docs/27: this build's entitlements structurally exclude
        // CloudKit (the free Personal Team cannot provision it), so sync can never be
        // enabled here regardless of what's stored — forced off rather than merely
        // defaulted off, so a value written by a prior paid-team install can't leak through.
        return .disabled
        #else
        return SyncPreference(isEnabled: defaults.bool(forKey: isEnabledKey))
        #endif
    }

    static func setEnabled(_ enabled: Bool) {
        #if KUE_PERSONAL_BUILD
        return // see `current` above — this build can never turn sync on.
        #else
        defaults.set(enabled, forKey: isEnabledKey)
        #endif
    }
}
