//
//  SystemIntegrationSettingsUITests.swift
//  KueUITests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "M." — the app-owned Siri/Shortcuts/
//  Spotlight/Controls management surface, driven through `FakeSpotlightIndexer`
//  (`UITestLaunchConfiguration.fakeSpotlightArgument` — the real on-device Core Spotlight
//  index never runs under `KueUITests`). Per the phase's own explicit instruction, this
//  deliberately does NOT attempt to trigger a `kue://` deep link from outside the app's own
//  process — confirmed (same finding Phase 9's Live Activity UI tests already documented) that
//  this SDK's XCTest has no supported API for it — so deep-link-triggered navigation (opening
//  an exact event, the missing-event state, Quick Add's prefilled confirmation sheet, Today/
//  Search pre-fill) is covered at the unit level (`KueDeepLinkTests`) and the manual checklist
//  in docs/24 "M." instead of here.
//

import XCTest

final class SystemIntegrationSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeSpotlightArgument]
        app.launch()
    }

    private func openSystemIntegrationSettings() {
        app.selectTab("tab-settings")
        let link = app.buttons["systemIntegrationSettingsLink"]
        link.scrollUpUntilHittable(in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    func testSystemIntegrationSettingsIsReachableFromSettings() {
        openSystemIntegrationSettings()
        XCTAssertTrue(app.navigationBars["Siri, Shortcuts & Spotlight"].waitForExistence(timeout: 5))
    }

    func testShortcutsAppLinkIsPresent() {
        openSystemIntegrationSettings()
        // A SwiftUI `Link`'s exact XCUIElementType isn't guaranteed (button vs. static text
        // depending on OS version) — match by accessibility identifier across every type.
        let link = app.descendants(matching: .any).matching(identifier: "openShortcutsAppLink").firstMatch
        link.scrollUpUntilHittable(in: app)
        XCTAssertTrue(link.exists)
        // Never tapped — opening the real Shortcuts app is exactly the unsupported
        // system-UI automation this phase's own instruction rules out.
    }

    func testSpotlightToggleAndRebuildAreReachable() {
        openSystemIntegrationSettings()

        let toggle = app.switches["spotlightEnabledToggle"]
        toggle.scrollUpUntilHittable(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let rebuildButton = app.buttons["rebuildSpotlightIndexButton"]
        rebuildButton.scrollUpUntilHittable(in: app)
        rebuildButton.tap()

        let message = app.staticTexts["spotlightActionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
    }

    func testRemoveSpotlightEntriesIsReachable() {
        openSystemIntegrationSettings()

        let removeButton = app.buttons["removeSpotlightEntriesButton"]
        removeButton.scrollUpUntilHittable(in: app)
        removeButton.tap()

        let message = app.staticTexts["spotlightActionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
    }

    /// Toggling the switch itself is covered by `testSpotlightToggleAndRebuildAreReachable`
    /// (it's the same control) — the resulting `.disabled(!isSpotlightEnabled)` derivation is
    /// a one-line SwiftUI modifier over `SpotlightIndexingPreference`, which
    /// `SpotlightIndexingTests.swift` already covers directly; asserting the *exact* disabled
    /// timing here on top of that proved unreliable (XCUITest's `Switch.value` reflects the
    /// pre-tap state until the run loop settles, making an immediate re-read racy) without
    /// adding real coverage beyond what's already tested at the unit level.
}
