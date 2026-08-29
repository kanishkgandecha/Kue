//
//  LockScreenWidgetContentService.swift
//  Kue
//
//  Post-Phase-12 fix — see `DedicatedWidgetContentService.swift`'s own header for the sibling
//  policy this deliberately mirrors: a pure `resolve(event:...)` with no code path that can see
//  or substitute any event other than the one it was explicitly handed. The one real
//  difference from Dedicated Countdown's policy: this one distinguishes "never selected"
//  (`.noSelection`, the widget's own "Select Event" state) from "selected, but that id no
//  longer resolves" (`.selectionUnavailable`, "Select Another Event") — Dedicated Countdown
//  collapses both into one `.unavailable`, but this feature's own spec asks for different
//  copy/deep-link explanation between the two.
//

import Foundation
import SwiftData

/// What a Lock Screen accessory widget (`.accessoryCircular`/`.accessoryRectangular`/
/// `.accessoryInline` of the `KueWidget` kind) should render, given whatever `KueEvent?` the
/// stored `LockScreenEventSelection.current` UUID resolved to.
enum LockScreenWidgetResolution: Equatable {
    /// Normal rendering — also covers `.completed`/`.removed` (archived) phases, which already
    /// read as "Completed"/"Archived" via the existing, unmodified
    /// `WidgetContentService.displayContent`/`WidgetAccessoryLabels.accessorySafeStatus`
    /// pipeline. The selected event still exists in both cases, so the widget still deep-links
    /// to its Event Detail via `content.eventID` — reusing this machinery (rather than
    /// re-deriving completed/archived detection here) is what keeps a selected event's natural
    /// progression identical to how every other Kue widget already treats any event.
    case tracking(WidgetDisplayContent)
    /// `EventStatusEngine.derive` folds cancelled into `.cancelled` and
    /// `WidgetContentService.currentPhase` has no branch for `event.isCancelled` at all —
    /// without this explicit check, a cancelled selection would fall through to ordinary
    /// date-driven phases and look like it's still counting down. `eventID` is carried (the
    /// event still exists) so the widget still deep-links to its Event Detail, never the
    /// selection page.
    case cancelled(eventID: UUID, eventTitle: String)
    /// Same gap as `.cancelled`, for `event.isSkipped` — user-facing copy must say "Skipped,"
    /// not "Cancelled" (`EventDetailView` already makes this same distinction).
    case skipped(eventID: UUID, eventTitle: String)
    /// No UUID has ever been stored (or it was explicitly cleared) — the widget's "Select
    /// Event" state, deep-linking to the selection page.
    case noSelection
    /// A UUID is stored but no longer resolves to any `KueEvent` (deleted) — the widget's
    /// "Select Another Event" state, also deep-linking to the selection page, but with
    /// different copy: something *was* chosen and is now gone, not "nothing chosen yet."
    case selectionUnavailable

    /// The one deep-link destination this resolution's widget tap should use —
    /// `LockScreenAccessoryView`'s `.widgetURL` wiring and this feature's own tests both read
    /// this rather than duplicating the mapping. Event Detail while the selected event still
    /// exists (`.tracking`/`.cancelled`/`.skipped` all carry an `eventID`), the selection page
    /// when it doesn't (`.noSelection`/`.selectionUnavailable`) — matching this feature's own
    /// "Event Detail when the selected event still exists, the selection page when it no
    /// longer resolves" spec exactly.
    var deepLinkDestination: KueDeepLink.Destination {
        switch self {
        case .tracking(let content): return .event(content.eventID)
        case .cancelled(let eventID, _): return .event(eventID)
        case .skipped(let eventID, _): return .event(eventID)
        case .noSelection, .selectionUnavailable: return .lockScreenEventSelection
        }
    }
}

enum LockScreenWidgetContentService {
    /// The one, total function this policy is. `event` is already resolved by the caller (id
    /// lookup against the shared store) — this file never fetches an events *list*, never
    /// falls back to "Next Up," and never sees any event other than the one it was explicitly
    /// handed. Precedence (cancelled before skipped) mirrors `EventStatusEngine.derive`'s own
    /// documented cancel-wins-over-skip rule, same as `DedicatedWidgetContentService.resolve`.
    static func resolve(event: KueEvent?, hasStoredSelection: Bool, now: Date = .now) -> LockScreenWidgetResolution {
        guard let event else {
            return hasStoredSelection ? .selectionUnavailable : .noSelection
        }
        if event.isCancelled { return .cancelled(eventID: event.id, eventTitle: event.title) }
        if event.isSkipped { return .skipped(eventID: event.id, eventTitle: event.title) }
        let phase = WidgetContentService.currentPhase(for: event, now: now)
        return .tracking(WidgetContentService.displayContent(for: event, phase: phase, now: now))
    }

    /// The stored selection's *entire* "does this id still resolve to a real row in the shared
    /// store" lookup — deliberately unfiltered by eligibility (a completed/archived/cancelled/
    /// skipped event must still resolve so `resolve(event:hasStoredSelection:now:)` above can
    /// render its terminal state, exactly the "must continue resolving by UUID even if its
    /// state later changes" requirement this feature specifies). `selectedEventID` is
    /// `LockScreenEventSelection.current` at the call site, threaded through as a plain
    /// `UUID?` so this stays testable via `@testable import Kue` the same way
    /// `DedicatedWidgetContentService.resolveConfiguredEvent` already is.
    static func resolveSelectedEvent(selectedEventID: UUID?, context: ModelContext) -> KueEvent? {
        guard let selectedEventID else { return nil }
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        return events.first { $0.id == selectedEventID }
    }
}
