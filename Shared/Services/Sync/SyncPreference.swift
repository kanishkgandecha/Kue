//
//  SyncPreference.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Background behavior." The explicit Sync on/off setting. App Group
//  `UserDefaults`-backed, the same established pattern `ReminderPreference`/
//  `LiveActivityPrivacyPreference`/`SpotlightIndexingPreference` already use for a device-
//  scoped preference that needs no SwiftData schema change. **Conservative default for
//  existing installations**: `isEnabled` defaults to `false` — sync is strictly opt-in, never
//  silently turned on for someone who's been using local-only Kue.
//
//  Kue 2.0 Phase 12's own `KUE_PERSONAL_BUILD` forcing (CloudKit sync structurally required a
//  paid Apple Developer Program membership a free Personal Team can't provide) is **removed**
//  this phase — docs/33 "CloudKit retirement": Supabase sync needs only network access and a
//  signed-in account, both available in every build configuration. `SyncCoordinator` itself
//  still gates on `SupabaseConfiguration.current` being non-`nil` (requirement L: "missing
//  Supabase configuration leaves the app fully local").
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
