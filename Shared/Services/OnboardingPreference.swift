//
//  OnboardingPreference.swift
//  Kue
//
//  Kue 2.0 Phase 12 — presentation state only. Kept out of SwiftData so showing or
//  completing onboarding can never trigger a schema migration or alter user content.
//

import Foundation

enum OnboardingPreference {
    private static let completedVersionKey = "onboarding.completedVersion"
    static let currentVersion = 2

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }

    static var shouldPresent: Bool {
        // Existing UI suites launch hundreds of isolated app processes and are not tests of
        // onboarding. The dedicated argument leaves it visible for focused coverage.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestShowOnboarding") { return true }
        if arguments.contains(ModelContainerFactory.uiTestLaunchArgument),
           !arguments.contains("-uiTestShowOnboarding") {
            return false
        }
        return defaults.integer(forKey: completedVersionKey) < currentVersion
    }

    static func markCompleted() {
        defaults.set(currentVersion, forKey: completedVersionKey)
    }
}
