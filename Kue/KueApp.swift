//
//  KueApp.swift
//  Kue
//
//  Created by Kanishk Gandecha on 25/08/26.
//

import SwiftUI
import SwiftData

@main
struct KueApp: App {
    let modelContainer: ModelContainer = ModelContainerFactory.makeDefault()

    var body: some Scene {
        WindowGroup {
            HomeView()
                // Real, on-device-only implementations — see docs/06-ai-layer.md "Parser
                // runtime & credentials". Everywhere else in the app reads these only through
                // the `NLParsing`/`AIAvailabilityChecking` environment seam (AIEnvironment.swift),
                // so KueTests can swap in fixture-backed fakes and never reach this line.
                .environment(\.nlParser, FoundationModelsParser())
                .environment(\.aiAvailabilityChecker, SystemAIAvailabilityChecker())
        }
        .modelContainer(modelContainer)
    }
}
