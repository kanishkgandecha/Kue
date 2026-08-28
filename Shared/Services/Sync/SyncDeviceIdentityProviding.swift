//
//  SyncDeviceIdentityProviding.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "G./R." A stable-per-install, privacy-safe device identifier —
//  never an Apple ID, name, or anything that could identify the person, only used to label
//  *which installation* produced a given local mutation for diagnostics (docs/26 "N.":
//  privacy-safe logging) and, if ever needed, as a non-authoritative debugging aid. Never
//  used as the conflict-resolution tie-break itself — `SyncConflictResolver`'s own header
//  explains why that must stay device-independent.
//

import Foundation

nonisolated protocol SyncDeviceIdentityProviding: Sendable {
    /// A random, non-reversible identifier generated once and persisted locally — not
    /// `identifierForVendor` (which can change on app reinstall in ways that would silently
    /// orphan diagnostics, not that this matters for correctness, only debugging clarity).
    var deviceIdentifier: String { get }
}

nonisolated struct SystemSyncDeviceIdentityProvider: SyncDeviceIdentityProviding {
    private static let key = "sync.deviceIdentifier"
    // Same "static let, computed fresh each access, no stored UserDefaults property" shape
    // `ReminderPreference`/`LiveActivityPrivacyPreference` already establish — avoids storing
    // a non-`Sendable` `UserDefaults` instance on a `Sendable`-conforming type.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }

    init() {}

    var deviceIdentifier: String {
        if let existing = Self.defaults.string(forKey: Self.key) { return existing }
        let fresh = UUID().uuidString
        Self.defaults.set(fresh, forKey: Self.key)
        return fresh
    }
}

final class FakeSyncDeviceIdentityProvider: SyncDeviceIdentityProviding, @unchecked Sendable {
    var deviceIdentifier: String
    init(deviceIdentifier: String = "fake-device-A") {
        self.deviceIdentifier = deviceIdentifier
    }
}
