//
//  SystemIntegrationEnvironment.swift
//  Kue
//
//  Dependency injection for Phase 10's Spotlight seam — mirrors `LiveActivityEnvironment.swift`
//  (Phase 9) exactly. `KueApp` installs `SystemSpotlightIndexer.shared` by default, or (under
//  `FakeSpotlightIndexer.uiTestLaunchArgument`) a deterministic fake, resolved once at launch
//  the same way Phase 9's own bug fix requires (see `KueApp.liveActivityManager`'s doc comment)
//  — never inline in `body`.
//

import SwiftUI

private struct SpotlightIndexerKey: EnvironmentKey {
    static let defaultValue: SpotlightIndexing = SystemSpotlightIndexer.shared
}

extension EnvironmentValues {
    var spotlightIndexer: SpotlightIndexing {
        get { self[SpotlightIndexerKey.self] }
        set { self[SpotlightIndexerKey.self] = newValue }
    }
}
