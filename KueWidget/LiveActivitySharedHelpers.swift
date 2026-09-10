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
import AppIntents

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

// MARK: - Action rendering (Kue 3.0 Phase 2, docs/30 "Action policy")

/// How much of an action's identity a given region has room to show — never more than a short
/// word plus its icon; icon-only regions still carry the full word as an `.accessibilityLabel`
/// (attached by the caller, since a `Link`/`Button` label's own accessibility value already
/// reads the icon-only text otherwise, which VoiceOver users would hear as nothing meaningful).
enum LiveActivityActionLabelStyle {
    case full, compact, iconOnly
}

/// The one place a `LiveActivityAction` becomes an actual `Button`/`Link` — reused by the Lock
/// Screen and every Dynamic Island region so the same action always looks/behaves identically
/// everywhere it appears. Reuses the **existing** App Intents (`CompleteTaskIntent`/
/// `SnoozeTaskIntent`/`CompleteEventIntent`) and `KueDeepLink` verbatim — no duplicated
/// mutation logic. Styling (`.buttonStyle`/`.tint`/`.controlSize`) is the caller's job, since
/// that differs per region.
@ViewBuilder
func actionControl(_ action: LiveActivityAction, style: LiveActivityActionLabelStyle) -> some View {
    switch action {
    case .completeTask(let taskID):
        Button(intent: CompleteTaskIntent(taskID: taskID)) {
            actionLabelContent(style: style, full: "Complete Task", compact: "Complete", systemImage: "checkmark.circle")
        }
        .accessibilityLabel("Complete Task")
    case .snoozeTask(let taskID):
        Button(intent: SnoozeTaskIntent(taskID: taskID)) {
            actionLabelContent(style: style, full: "Snooze", compact: "Snooze", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Snooze Task")
    case .markComplete(let eventID):
        Button(intent: CompleteEventIntent(eventID: eventID)) {
            actionLabelContent(style: style, full: "Mark Complete", compact: "Complete", systemImage: "flag.checkered")
        }
        .accessibilityLabel("Mark Complete")
    case .confirmOutcome(let eventID):
        Link(destination: KueDeepLink.url(for: .event(eventID))) {
            actionLabelContent(style: style, full: "Confirm Outcome", compact: "Review", systemImage: "questionmark.circle")
        }
        .accessibilityLabel("Confirm Outcome")
    case .openEvent(let eventID):
        Link(destination: KueDeepLink.url(for: .event(eventID))) {
            actionLabelContent(style: style, full: "More", compact: "More", systemImage: "ellipsis")
        }
        .accessibilityLabel("Open Event")
    }
}

/// The primary action's tint — the event accent everywhere except Confirm Outcome, which keeps
/// `.orange` (a distinct "needs your input" semantic from the event's own color identity,
/// consistent with how this app's other outcome-review surfaces already read).
func primaryActionTint(for action: LiveActivityAction, accent: Color) -> Color {
    if case .confirmOutcome = action { return .orange }
    return accent
}

@ViewBuilder
private func actionLabelContent(style: LiveActivityActionLabelStyle, full: String, compact: String, systemImage: String) -> some View {
    switch style {
    case .full: Label(full, systemImage: systemImage)
    case .compact: Label(compact, systemImage: systemImage)
    case .iconOnly: Image(systemName: systemImage)
    }
}
