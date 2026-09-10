//
//  MacUITestLaunchConfiguration.swift
//  KueMacUITests
//
//  Kue 3.0 Phase 1 — mirrors `KueUITests/UITestLaunchConfiguration.swift`'s own
//  `isolatedStoreArgument` exactly (the literal string must match `ModelContainerFactory
//  .uiTestLaunchArgument`, which every `KueMacUITests` case passes before `app.launch()`, the
//  same "shared literal, same rationale" as the iOS side — see that file's own header). This
//  is deliberately the only launch argument this phase needs: Mac Phase 1 has no Calendar/
//  OCR/Voice/Live Activity/Sync UI to fake, unlike the iOS target.
//

import XCTest

enum MacUITestLaunchConfiguration {
    /// Must match `ModelContainerFactory.uiTestLaunchArgument` exactly.
    static let isolatedStoreArgument = "-uiTestIsolatedStore"
}
