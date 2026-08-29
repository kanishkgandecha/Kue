//
//  LiveActivityEnvironment.swift
//  Kue
//
//  Dependency injection for `LiveActivityManaging` — mirrors `CalendarEnvironment.swift`'s
//  `\.calendarProvider` seam exactly. `KueApp` installs `SystemLiveActivityManager.shared` by
//  default, or (launched with `FakeLiveActivityManager.uiTestLaunchArgument`) a deterministic
//  fake — see that type's own header.
//

import SwiftUI

private struct LiveActivityManagerKey: EnvironmentKey {
    static let defaultValue: LiveActivityManaging = SystemLiveActivityManager.shared
}

extension EnvironmentValues {
    var liveActivityManager: LiveActivityManaging {
        get { self[LiveActivityManagerKey.self] }
        set { self[LiveActivityManagerKey.self] = newValue }
    }
}
