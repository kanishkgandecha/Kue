//
//  WidgetReloading.swift
//  Kue
//
//  Dependency-injection seam around `WidgetCenter.shared.reloadTimelines(ofKind:)` — Phase 9
//  requirement: "timeline reload invocation through an injectable wrapper." Lives in Shared/
//  (not app-only) because the widget extension's own App Intents (CompleteTaskIntent,
//  SnoozeTaskIntent, CompleteEventIntent) need to trigger a reload too, from inside the
//  extension process — `EventActions.reloadWidget()` (Kue/, app-only) stays as the app's own
//  call site and is untouched; this is the same underlying WidgetKit call, just reachable
//  from both targets and swappable in tests.
//

import Foundation
import WidgetKit

protocol WidgetReloading {
    func reloadTimelines(ofKind kind: String)
}

/// `nonisolated` — otherwise `.shared` can't be used as a default parameter value under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (see AGENTS.md's concurrency note).
nonisolated final class SystemWidgetReloader: WidgetReloading {
    static let shared = SystemWidgetReloader()
    private init() {}

    func reloadTimelines(ofKind kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
