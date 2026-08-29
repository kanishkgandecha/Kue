//
//  LiveActivitySharedHelpers.swift
//  KueWidget
//
//  Post-Phase-12 fix — split out of the former single `LiveActivityViews.swift` so the Lock
//  Screen redesign and the Dynamic Island redesign could proceed as independent, non-
//  conflicting files. Everything here is shared read-only state derivation — no layout code —
//  used by both `LiveActivityLockScreenView.swift` and `LiveActivityDynamicIslandViews.swift`.
//  See docs/23-live-activities-and-focus-mode.md "D./E." for the original contract; see
//  docs/23 "K." for this redesign's own notes.
//

import SwiftUI
import WidgetKit
import ActivityKit

typealias ContentState = KueLiveActivityAttributes.ContentState

/// A restrained text wordmark, not the real asset — `Kue/Assets.xcassets/KueWordmark
/// .imageset` lives in the app target's own catalog only; duplicating the file into
/// `KueWidget`'s catalog would be exactly the "introducing duplicate logo files" Phase 7's own
/// wordmark requirement rules out. This is the same restrained-text fallback treatment
/// `KueWordmark` itself uses when the asset isn't available.
struct KueMark: View {
    var body: some View {
        Text("Kue")
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false) // never truncate/clip the mark itself
            .accessibilityHidden(true) // decorative — the surrounding content already names Kue
    }
}

func statusLine(_ state: ContentState) -> String {
    if let terminal = state.terminal {
        switch terminal {
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .unavailable: return "Event Removed"
        }
    }
    switch state.phase {
    case .awaitingOutcome: return "Needs Review"
    case .completed: return "Completed"
    case .removed: return "Archived"
    default: return state.countdownSubline ?? state.eventTypeDisplayName
    }
}

func isTerminalOrDone(_ state: ContentState) -> Bool {
    state.terminal != nil || state.phase == .completed || state.phase == .removed
}

func statusSymbol(_ state: ContentState) -> String {
    if let terminal = state.terminal {
        switch terminal {
        case .cancelled: return "xmark.circle"
        case .skipped: return "arrow.uturn.forward.circle"
        case .unavailable: return "questionmark.circle"
        }
    }
    switch state.phase {
    case .awaitingOutcome: return "questionmark.circle"
    case .completed: return "checkmark.circle.fill"
    case .removed: return "archivebox"
    default: return state.isUrgent ? "exclamationmark.triangle.fill" : "clock"
    }
}

/// Post-Phase-12 fix — the one place `EventTypeAccent` is applied *conditionally*: `isUrgent`
/// is a treatment layered on top of the event-type accent, not a replacement lifecycle policy
/// (`WidgetContentService`'s own "urgent is not a lifecycle phase" comment, reused here) —
/// while genuinely tracking (`state.terminal == nil`) and urgent, red communicates "this needs
/// attention now" more clearly than the event's own type color would; every other state keeps
/// its type accent so the card still visibly belongs to Kue's color system.
func activeAccentColor(eventType: EventType, state: ContentState) -> Color {
    if state.terminal == nil, state.isUrgent, state.phase != .completed, state.phase != .removed {
        return .red
    }
    return EventTypeAccent.color(for: eventType)
}
