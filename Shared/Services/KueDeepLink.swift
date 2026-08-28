//
//  KueDeepLink.swift
//  Kue
//
//  See docs/22-expanded-and-dedicated-widgets.md "E." — the one shared literal (scheme +
//  path shape) both the widget extension (constructing `.widgetURL`s) and the app
//  (`.onOpenURL` parsing them) must agree on exactly, same "shared constant" rationale
//  `WidgetKind`/`UITestLaunchConfiguration` already establish for their own cross-target
//  literals. Pure — no WidgetKit/SwiftUI import — so both sides and KueTests can use it
//  identically.
//

import Foundation

/// `nonisolated` — this module defaults new types to `@MainActor`
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`, see AGENTS.md's concurrency note); `Destination`'s
/// `Equatable` conformance needs to be usable from Swift Testing's `#expect`, which runs off
/// the main actor, same reason `SchedulingEngine.ScheduledTaskPlan`/`NotificationCandidate`
/// are marked this way.
nonisolated enum KueDeepLink {
    static let scheme = "kue"

    nonisolated enum Destination: Equatable {
        /// A specific event's Detail screen — used for a resolvable Dedicated Countdown tap,
        /// tracking or terminal-but-still-a-real-row (completed/archived/cancelled/skipped).
        case event(UUID)
        /// The event is genuinely gone (deleted) or was never configured — an honest
        /// explanation, not a fabricated "choose another event" in-app control (docs/22 "E.").
        case dedicatedCountdownHelp
    }

    static func url(for destination: Destination) -> URL {
        switch destination {
        case .event(let id):
            // Force-unwrap is safe: `id.uuidString` is always a valid URL path component.
            return URL(string: "\(scheme)://event/\(id.uuidString)")!
        case .dedicatedCountdownHelp:
            return URL(string: "\(scheme)://dedicated-countdown-help")!
        }
    }

    /// `nil` for any URL that isn't Kue's own scheme, or a malformed/unrecognized one —
    /// requirement: "Validate deep links and handle missing identifiers safely."
    static func parse(_ url: URL) -> Destination? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case "event":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return .event(id)
        case "dedicated-countdown-help":
            return .dedicatedCountdownHelp
        default:
            return nil
        }
    }
}
