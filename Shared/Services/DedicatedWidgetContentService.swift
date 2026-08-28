//
//  DedicatedWidgetContentService.swift
//  Kue
//
//  See docs/22-expanded-and-dedicated-widgets.md "C. Three separately-testable selection
//  policies" / "D. Terminal states" — the strict Dedicated Countdown resolution policy, kept
//  entirely separate from `WidgetContentService.nextUpEvent`'s automatic policy and
//  `KueEventProvider.resolveEvent`'s configured-with-fallback policy. This file has no code
//  path that can substitute a different event for the one it was given — that's the whole
//  point of "dedicated." `resolve(event:now:)` itself is pure (no WidgetKit/SwiftData
//  imports needed for it). `resolveConfiguredEvent(selectedEventID:context:)` below is the
//  one SwiftData-touching exception — `DedicatedCountdownProvider.resolveConfiguredEvent`
//  (KueWidget/) moved its lookup here so it's reachable by `@testable import Kue`, same
//  established shape as `WidgetIntentActions` (Shared/) wrapping logic the widget
//  extension's own `AppIntent` structs can't be tested directly (see that file's header).
//

import Foundation
import SwiftData

/// What a Dedicated Countdown widget instance should render, given whatever `KueEvent?` its
/// provider resolved by the configured id (`nil` covers "never configured," "deleted," and
/// "store unreachable" alike — see `resolve(event:now:)`'s own doc comment for why those
/// collapse into one case here).
enum DedicatedWidgetResolution: Equatable {
    /// Normal rendering — this also covers `.completed`/`.removed` phases, which already
    /// read as "Completed"/"Archived" via the existing, unmodified
    /// `WidgetContentService.displayContent` copy. Reusing that machinery (rather than
    /// re-deriving completed/archived detection here) is what keeps a pinned event's natural
    /// Completed → Archived progression identical to how every other Kue widget already
    /// treats any event.
    case tracking(WidgetDisplayContent)
    /// `EventStatusEngine.derive` folds cancelled into `.cancelled` and
    /// `WidgetContentService.currentPhase` has no branch for `event.isCancelled` at all —
    /// without this explicit check, a cancelled event's dedicated widget would fall through
    /// to ordinary date-driven phases and look like it's still counting down. `eventID` is
    /// carried (not just the title) because the event still exists — E's "Choose Another
    /// Event" deep-link still targets it, same as a normally-tracking one.
    case cancelled(eventID: UUID, eventTitle: String)
    /// Same gap as `.cancelled`, for `event.isSkipped` — `derive` folds it into `.cancelled`
    /// too, but the user-facing copy must say "Skipped," not "Cancelled" (`EventDetailView`
    /// already makes this same distinction for the same reason).
    case skipped(eventID: UUID, eventTitle: String)
    /// The configured id was never set, no longer resolves to any `KueEvent` (deleted), or
    /// the store couldn't be opened at all — from this widget's own perspective, all three
    /// require the identical honest response ("choose another event"), so a single case is
    /// the real distinction, not a false one.
    case unavailable
}

enum DedicatedWidgetContentService {
    /// The one, total function this policy is. `event` is already resolved by the caller
    /// (id lookup against the shared store) — this file never fetches, never falls back to
    /// "Next Up," and never sees any event other than the one it was explicitly handed.
    /// Precedence (cancelled before skipped) mirrors `EventStatusEngine.derive`'s own
    /// documented cancel-wins-over-skip rule.
    static func resolve(event: KueEvent?, now: Date = .now) -> DedicatedWidgetResolution {
        guard let event else { return .unavailable }
        if event.isCancelled { return .cancelled(eventID: event.id, eventTitle: event.title) }
        if event.isSkipped { return .skipped(eventID: event.id, eventTitle: event.title) }
        let phase = WidgetContentService.currentPhase(for: event, now: now)
        return .tracking(WidgetContentService.displayContent(for: event, phase: phase, now: now))
    }

    /// The provider's *entire* "does the configured id still resolve to a real row in the
    /// shared store" lookup — deliberately unfiltered by eligibility (a completed/archived/
    /// cancelled/skipped event must still resolve so `resolve(event:now:)` above can render
    /// its terminal state, per docs/22 "D."). `selectedEventID` is `configuration.event?.id`
    /// at the call site; passed as a plain `UUID?` here (not the `AppEntity` itself) since
    /// `KueWidget/`'s `AppEntity`/`WidgetConfigurationIntent` types don't compile into the
    /// `Kue` module `@testable import Kue` sees.
    static func resolveConfiguredEvent(selectedEventID: UUID?, context: ModelContext) -> KueEvent? {
        guard let selectedEventID else { return nil }
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        return events.first { $0.id == selectedEventID }
    }
}
