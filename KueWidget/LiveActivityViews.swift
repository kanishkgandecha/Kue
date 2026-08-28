//
//  LiveActivityViews.swift
//  KueWidget
//
//  See docs/23-live-activities-and-focus-mode.md "D./E." — Lock Screen + every Dynamic
//  Island region. Every value here already came from `KueLiveActivityAttributes.ContentState`
//  — no re-fetching, no re-deriving privacy (that's `LiveActivityStateBuilder`'s job, applied
//  before the state ever reaches ActivityKit's own storage). Same plain-system-material idiom
//  `KueWidgetEntryView`/`DedicatedCountdownEntryView` already established for this target —
//  `Kue/DesignSystem/`'s SwiftUI tokens don't compile into `KueWidget` (Phase 7/8's own
//  established constraint), so this is "the design system as applied within that limit," not
//  a second styling system.
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
private struct KueMark: View {
    var body: some View {
        Text("Kue")
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true) // decorative — the surrounding content already names Kue
    }
}

private func statusLine(_ state: ContentState) -> String {
    if let terminal = state.terminal {
        switch terminal {
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .unavailable: return "Event Removed"
        }
    }
    switch state.phase {
    case .completed: return "Completed"
    case .removed: return "Archived"
    default: return state.countdownSubline ?? state.eventTypeDisplayName
    }
}

private func isTerminalOrDone(_ state: ContentState) -> Bool {
    state.terminal != nil || state.phase == .completed || state.phase == .removed
}

private func statusSymbol(_ state: ContentState) -> String {
    if let terminal = state.terminal {
        switch terminal {
        case .cancelled: return "xmark.circle"
        case .skipped: return "arrow.uturn.forward.circle"
        case .unavailable: return "questionmark.circle"
        }
    }
    switch state.phase {
    case .completed: return "checkmark.circle.fill"
    case .removed: return "archivebox"
    default: return state.isUrgent ? "exclamationmark.triangle.fill" : "clock"
    }
}

// MARK: - Lock Screen

struct LiveActivityLockScreenView: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(state.eventTypeDisplayName.uppercased(), systemImage: statusSymbol(state))
                    .font(.caption2)
                    .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                KueMark()
            }

            Text(state.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.8) // requirement D: no clipping at extreme Dynamic Type

            Text(statusLine(state))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if state.terminal == nil, state.tasksTotal > 0 {
                ProgressView(value: Double(state.tasksCompleted), total: Double(state.tasksTotal))
                    .tint(.accentColor)
                HStack(spacing: 4) {
                    if let nextTask = state.nextTaskSummary {
                        Text(nextTask).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(state.remainingTaskCount) left")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            // Section H — reuses the exact same App Intents the ordinary widgets already use;
            // omitted entirely (not shown disabled) once the event is terminal, matching
            // "omit rather than presenting a nonfunctional control."
            if state.terminal == nil, state.phase != .completed, state.phase != .removed {
                HStack(spacing: 8) {
                    if let nextTaskID = state.nextTaskID {
                        Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                            Label("Complete Task", systemImage: "checkmark.circle")
                        }
                        .font(.caption2)
                        if state.canSnoozeNextTask {
                            Button(intent: SnoozeTaskIntent(taskID: nextTaskID)) {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .font(.caption2)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Label("Mark Complete", systemImage: "flag.checkered")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .activityBackgroundTint(Color(uiColor: .systemBackground))
        .activitySystemActionForegroundColor(.primary)
    }
}

// MARK: - Dynamic Island: expanded

struct LiveActivityDynamicIslandExpandedLeading: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            KueMark()
            Text(state.eventTypeDisplayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct LiveActivityDynamicIslandExpandedTrailing: View {
    let state: ContentState

    var body: some View {
        Image(systemName: statusSymbol(state))
            .font(.title3)
            .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .primary)
    }
}

struct LiveActivityDynamicIslandExpandedCenter: View {
    let state: ContentState

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
                    .tint(.accentColor)
                Text("\(state.tasksCompleted) of \(state.tasksTotal) tasks · \(state.remainingTaskCount) left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if state.terminal == nil, state.phase != .completed, state.phase != .removed {
                HStack(spacing: 8) {
                    if let nextTaskID = state.nextTaskID {
                        Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                            Label("Complete Task", systemImage: "checkmark.circle")
                        }
                    }
                    Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                        Label("Mark Complete", systemImage: "flag.checkered")
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }
}

// MARK: - Dynamic Island: compact + minimal

struct LiveActivityCompactLeading: View {
    let state: ContentState

    var body: some View {
        Image(systemName: statusSymbol(state))
            .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .primary)
    }
}

struct LiveActivityCompactTrailing: View {
    let state: ContentState

    var body: some View {
        Text(WidgetAccessoryLabels.accessorySafeStatus(phase: state.phase, subline: state.countdownSubline))
            .font(.caption2)
            .fontWeight(.semibold)
            .lineLimit(1)
    }
}

struct LiveActivityMinimal: View {
    let state: ContentState

    var body: some View {
        Image(systemName: statusSymbol(state))
            .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .primary)
    }
}
