//
//  LiveActivityDynamicIslandViews.swift
//  KueWidget
//
//  See docs/23-live-activities-and-focus-mode.md "D./E." — every Dynamic Island region.
//  Post-Phase-12 fix — visual redesign (docs/23 "K."): event-type accent, one clear purpose
//  per region, no duplicated title/countdown across regions. Shared helpers (`ContentState`,
//  `statusLine`/`statusSymbol`/`activeAccentColor`, `KueMark`) live in
//  `LiveActivitySharedHelpers.swift`, used identically by the Lock Screen's own file — no
//  lifecycle policy is re-derived here.
//

import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

// MARK: - Expanded

struct LiveActivityDynamicIslandExpandedLeading: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // Leading names the event's type, not Kue's own brand — the Lock Screen card already
    // carries `KueMark`, Expanded doesn't need to repeat it. The icon is `statusSymbol`
    // (the same lifecycle glyph every other region uses) tinted with the event's accent, so
    // Leading and Trailing never fight over which one "owns" the status icon — Leading pairs
    // it with the type name, Trailing (below) pairs the same information with countdown text.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: statusSymbol(state))
                .font(.caption)
                .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
                .accessibilityLabel(statusLine(state))
            Text(state.eventTypeDisplayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct LiveActivityDynamicIslandExpandedTrailing: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // Trailing carries the countdown/lifecycle text (the same `accessorySafeStatus` string
    // Compact Trailing shows), tinted with the event accent — this struct has `attributes`,
    // `ExpandedCenter` doesn't, so the accent naturally lives here rather than on the status
    // line below the title. Center's own status line therefore stays a plain secondary
    // caption: the state description reads in exactly one tinted place, not two.
    var body: some View {
        Text(WidgetAccessoryLabels.accessorySafeStatus(phase: state.phase, subline: state.countdownSubline))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(statusLine(state))
    }
}

struct LiveActivityDynamicIslandExpandedCenter: View {
    let state: ContentState

    // No `attributes` here, so no event accent to apply — by design, per `ExpandedTrailing`'s
    // own comment above: the tinted state text already lives in Trailing, so this stays a
    // plain secondary caption rather than a second, redundant emphasis.
    var body: some View {
        VStack(spacing: 2) {
            Text(state.displayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(statusLine(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct LiveActivityDynamicIslandExpandedBottom: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.terminal == nil, state.tasksTotal > 0 {
                ProgressView(value: Double(state.tasksCompleted), total: Double(state.tasksTotal))
                    .tint(activeAccentColor(eventType: attributes.eventType, state: state))
                Text("\(state.tasksCompleted) of \(state.tasksTotal) tasks · \(state.remainingTaskCount) left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // `actionSet(for:)` (Shared/) is the one place this decision is stated — the Lock
            // Screen's own actions section reads the same function.
            switch actionSet(for: state) {
            case .activeWithNextTask, .activeNoNextTask:
                actionRow
            case .awaitingOutcome:
                Link(destination: KueDeepLink.url(for: .event(attributes.eventID))) {
                    Label("Confirm Outcome", systemImage: "questionmark.circle")
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
            case .none:
                EmptyView()
            }
        }
    }

    // Complete Task (when there's a next task) or Mark Complete (when there isn't) is the
    // primary action — `.borderedProminent` tinted with the event's own accent — the other
    // stays a plain `.bordered` secondary. `ViewThatFits` falls back from full labeled
    // buttons to icon-only ones (each carrying its own `.accessibilityLabel`) rather than ever
    // dropping an action to make the row fit this narrow region.
    @ViewBuilder
    private var actionRow: some View {
        let accent = activeAccentColor(eventType: attributes.eventType, state: state)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if let nextTaskID = state.nextTaskID {
                    Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                        Label("Complete Task", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Label("Mark Complete", systemImage: "flag.checkered")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Label("Mark Complete", systemImage: "flag.checkered")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                }
            }
            HStack(spacing: 8) {
                if let nextTaskID = state.nextTaskID {
                    Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityLabel("Complete Task")
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Image(systemName: "flag.checkered")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Mark Complete")
                } else {
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Image(systemName: "flag.checkered")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .accessibilityLabel("Mark Complete")
                }
            }
        }
        .font(.caption2)
        .controlSize(.mini)
    }
}

// MARK: - Compact + minimal

struct LiveActivityCompactLeading: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    var body: some View {
        Image(systemName: statusSymbol(state))
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .accessibilityLabel(statusLine(state))
    }
}

struct LiveActivityCompactTrailing: View {
    let state: ContentState

    // No `attributes` on this struct (its call site only ever passes `state:`), so there's no
    // `eventType` to build an accent from here — `.primary` also simply reads clearest against
    // the system's own compact-trailing background in this famously tiny, high-contrast-
    // required region. `.monospacedDigit()` keeps a shrinking day count ("128d" → "3d") from
    // jittering the pill's width, and the scale factor guards the 3-digit case.
    var body: some View {
        Text(WidgetAccessoryLabels.accessorySafeStatus(phase: state.phase, subline: state.countdownSubline))
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct LiveActivityMinimal: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // A single small tinted icon — no background fill — is enough at this size; the color
    // stays sparing while still carrying the event's own accent identity.
    var body: some View {
        Image(systemName: statusSymbol(state))
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .accessibilityLabel(statusLine(state))
    }
}
