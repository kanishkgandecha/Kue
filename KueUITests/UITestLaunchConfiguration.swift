//
//  UITestLaunchConfiguration.swift
//  KueUITests
//
//  Kue 2.0 Phase 3 post-implementation cleanup — UI-test store isolation. Every `KueUITests`
//  case that drives the real app passes `isolatedStoreArgument` via
//  `XCUIApplication.launchArguments` before `app.launch()`; `ModelContainerFactory` (Shared/,
//  compiled into the app target — `KueUITests` itself has no access to it, since it drives
//  the app externally rather than importing its module) recognizes the *same literal string*
//  and, only when present, opens a store outside the App Group container that's wiped clean
//  at the start of every launch. This one shared constant is what keeps the two sides of that
//  contract from silently drifting apart — see `ModelContainerFactory.uiTestLaunchArgument`'s
//  own header for the full rationale and the safety argument for why this can never reach
//  production data.
//

import XCTest

enum UITestLaunchConfiguration {
    /// Must match `ModelContainerFactory.uiTestLaunchArgument` exactly.
    static let isolatedStoreArgument = "-uiTestIsolatedStore"

    /// The simulator's interface orientation is a *device*-level property, not scoped to one
    /// app process — it doesn't reset just because a test relaunches the app. A stray rotation
    /// left over from an earlier test (or an earlier run against the same booted simulator)
    /// otherwise carries into every later test's layout math, which is exactly the kind of
    /// hidden execution-order dependency this cleanup is meant to remove. Call once per test
    /// class's `setUpWithError`, before `app.launch()`, so every test always starts portrait
    /// regardless of what any earlier test left the simulator in.
    static func resetDeviceOrientation() {
        XCUIDevice.shared.orientation = .portrait
    }
}
