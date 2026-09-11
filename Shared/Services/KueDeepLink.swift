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
        /// Kue 2.0 Phase 10 — opens the Add tab's manual entry form directly (no NL text).
        case quickAdd
        /// Opens the Add tab and re-runs the *same* `NLParsingPipeline` a typed Quick Add
        /// would, presenting the identical prefilled-confirmation `EventFormView` sheet
        /// (docs/24 "F.") — the raw text travels in the URL, not a pre-parsed draft, so the
        /// app always re-parses through the one real pipeline rather than deserializing an
        /// intermediate AI result across a process boundary.
        case addFromText(String)
        /// Home's date-sectioned timeline already shows Today at the top — this exists so a
        /// deep link can land there explicitly (Siri "show today's events," a Control Widget)
        /// without a caller needing to know Home is the right tab.
        case today
        /// Opens the Search tab, optionally with a query pre-filled.
        case search(String?)
        case templates
        /// Opens Settings' Focus management surface (docs/23 "F.") — the one place a focused
        /// Live Activity can be reviewed/stopped outside Event Detail.
        case liveActivityFocus
        /// Post-Phase-12 fix — the Lock Screen widget's own empty/unavailable-state tap target
        /// (`.accessoryCircular`/`.accessoryRectangular`/`.accessoryInline` of the `KueWidget`
        /// kind). Carries no event id itself — the in-app selection page reads
        /// `LockScreenEventSelection.current` directly to decide "nothing chosen yet" vs
        /// "chosen, but that event is gone" copy, so this one route covers both.
        case lockScreenEventSelection
        /// Kue 3.0 Phase 4 — docs/32 "Deep links." A parsed `kue://auth/callback` (email
        /// confirmation, password recovery, or another Supabase auth callback type). Carries
        /// only the parsed payload — never a raw event id or anything that could let an
        /// authentication callback navigate to or mutate an arbitrary event (requirement J).
        case authCallback(AccountAuthCallbackPayload)
    }

    static func url(for destination: Destination) -> URL {
        switch destination {
        case .event(let id):
            // Force-unwrap is safe: `id.uuidString` is always a valid URL path component.
            return URL(string: "\(scheme)://event/\(id.uuidString)")!
        case .dedicatedCountdownHelp:
            return URL(string: "\(scheme)://dedicated-countdown-help")!
        case .quickAdd:
            return URL(string: "\(scheme)://quick-add")!
        case .addFromText(let text):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "quick-add-text"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
            // Force-unwrap is safe: `URLComponents` percent-encodes the query item itself.
            return components.url!
        case .today:
            return URL(string: "\(scheme)://today")!
        case .search(let query):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "search"
            if let query, !query.isEmpty {
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
            return components.url!
        case .templates:
            return URL(string: "\(scheme)://templates")!
        case .liveActivityFocus:
            return URL(string: "\(scheme)://focus")!
        case .lockScreenEventSelection:
            return URL(string: "\(scheme)://widgets/lock-screen/select")!
        case .authCallback:
            // Never actually constructed by Kue itself — the URL comes from Supabase's own
            // email templates, already pointed at `AccountDeepLinkSupport.callbackURL`. This
            // arm exists only so `Destination` stays exhaustively switchable.
            return AccountDeepLinkSupport.callbackURL
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
        case "quick-add":
            return .quickAdd
        case "quick-add-text":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .addFromText(text)
        case "today":
            return .today
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            return .search(query)
        case "templates":
            return .templates
        case "focus":
            return .liveActivityFocus
        case "widgets":
            return url.path == "/lock-screen/select" ? .lockScreenEventSelection : nil
        case AccountDeepLinkSupport.host:
            // Kue 3.0 Phase 4 — validated fully inside `AccountDeepLinkSupport.parse` (exact
            // host + path + a recognized `type` + a matching token shape); `nil` here means
            // reject, exactly like every other unrecognized/malformed case in this function.
            return AccountDeepLinkSupport.parse(url).map(Destination.authCallback)
        default:
            return nil
        }
    }
}
