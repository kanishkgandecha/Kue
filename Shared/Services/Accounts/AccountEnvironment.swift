//
//  AccountEnvironment.swift
//  Kue
//
//  Kue 3.0 Phase 4 — dependency injection for `AccountProviding`, mirroring
//  `CalendarEnvironment.swift`'s `\.calendarProvider` seam exactly. Unlike Calendar/OCR/Voice,
//  there is no environment value for the *coordinator* itself — `AccountCoordinator` is an
//  `@Observable` object injected directly via `.environment(_:)` (the modern Observation-
//  framework pattern), not a `protocol`-typed `EnvironmentKey`. This value exists only so
//  `KueApp`/`KueMacApp` can resolve which `AccountProviding` to hand that coordinator at
//  construction time — real `SystemAccountProvider` normally, or (under
//  `FakeAccountProvider.uiTestLaunchArgument`) a deterministic fake, never real Supabase
//  credentials in a UI test (requirement M).
//

import SwiftUI

private struct AccountProviderKey: EnvironmentKey {
    static var defaultValue: AccountProviding? {
        SupabaseConfiguration.current.map { SystemAccountProvider(configuration: $0) }
    }
}

extension EnvironmentValues {
    var accountProvider: AccountProviding? {
        get { self[AccountProviderKey.self] }
        set { self[AccountProviderKey.self] = newValue }
    }
}
