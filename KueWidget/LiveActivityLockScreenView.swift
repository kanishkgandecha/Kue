//
//  LiveActivityLockScreenView.swift
//  KueWidget
//
//  See docs/23-live-activities-and-focus-mode.md "D./E." — the Lock Screen presentation.
//  Post-Phase-12 fix — visual redesign (docs/23 "K.") for a real-device defect report: the
//  card rendered almost entirely black with weak hierarchy, the "Kue" wordmark clipped at some
//  widths, the progress bar had low contrast, there was excessive empty space, and the three
//  action buttons were crowded oversized full-text pills. This file only changes layout/visual
//  treatment — no lifecycle policy is re-derived here. Shared helpers (`ContentState`,
//  `statusLine`/`statusSymbol`/`activeAccentColor`, `KueMark`) live in
//  `LiveActivitySharedHelpers.swift`, used identically by the Dynamic Island's own file.
//
//  Design decisions:
//  - Background: swapped the flat opaque `.systemBackground` tint (the likely "almost
//    entirely black" cause — plain `.systemBackground` under ActivityKit's own Lock Screen
//    dark rendering reads as pure black with no warmth) for the event's own accent at low
//    opacity (0.14, 0.06 under reduced luminance) — `.activityBackgroundTint` composites
//    whatever `Color` it's given over the system's own dark material, so a low-opacity accent
//    reads as "a dark neutral card with a subtle color identity" rather than a saturated fill.
//  - Header: leading status label gets `.layoutPriority(1)` so it never loses space to the
//    trailing `KueMark` wordmark; the wordmark itself already refuses to shrink
//    (`.fixedSize`), so priority only needs to protect the other side.
//  - Countdown/status line is tinted with `activeAccentColor` (red-for-urgent still wins,
//    exactly as that helper already decides) instead of a hardcoded `.red : .primary`
//    ternary, so a non-urgent card visibly carries its event-type color.
//  - Actions: `ViewThatFits` between a labeled row (preferred) and an icon-only row
//    (fallback) so a crowded narrow Lock Screen never clips a button — it downgrades to
//    icons with `.accessibilityLabel`s instead. Exactly one button is `.borderedProminent`
//    with the event accent as its primary action (Complete Task when a next task exists,
//    otherwise Mark Complete); the rest stay `.bordered`. Confirm Outcome keeps `.orange`
//    rather than the event accent — "needs your input before Kue can proceed" is a distinct,
//    attention-grabbing semantic from the event's own color identity, and `.orange` already
//    reads that way consistently elsewhere in this app's outcome-review flows.
//

import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

struct LiveActivityLockScreenView: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var accent: Color { activeAccentColor(eventType: attributes.eventType, state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            mainContent
            if state.terminal == nil, state.tasksTotal > 0 {
                progressSection
            }
            actionsSection
        }
        .padding(.vertical, 2)
        .activityBackgroundTint(backgroundTint)
        .activitySystemActionForegroundColor(.primary)
    }

    // MARK: - Header (requirement 1)

    private var header: some View {
        HStack {
            Label(state.eventTypeDisplayName.uppercased(), systemImage: statusSymbol(state))
                .font(.caption2)
                .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .secondary)
                .lineLimit(1)
                .layoutPriority(1) // protect the meaningful label; KueMark is already fixedSize
            Spacer(minLength: 4)
            KueMark()
        }
    }

    // MARK: - Main content (requirement 2)

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.8) // no clipping at extreme Dynamic Type

            Text(statusLine(state))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Progress / next task (requirement 3)

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(state.tasksCompleted), total: Double(state.tasksTotal))
                .progressViewStyle(.linear)
                .tint(accent)
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
    }

    // MARK: - Actions (requirement 4 — the core defect)

    @ViewBuilder
    private var actionsSection: some View {
        // Kue 2.0 Phase 10.1 — docs/25 "G.": Awaiting Outcome is neither terminal nor "still
        // tracking" — never offer a one-tap `CompleteEventIntent` here (that's exactly the
        // silent-completion risk this phase corrects); a `Link` to the outcome flow instead.
        // `actionSet(for:)` (Shared/) is the one place this three-way decision is stated —
        // the Dynamic Island's Expanded Bottom region reads the same function.
        switch actionSet(for: state) {
        case .activeWithNextTask, .activeNoNextTask:
            ViewThatFits {
                labeledActionRow
                iconOnlyActionRow
            }
        case .awaitingOutcome:
            Link(destination: KueDeepLink.url(for: .event(attributes.eventID))) {
                Label("Confirm Outcome", systemImage: "questionmark.circle")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.orange)
        case .none:
            // Terminal/completed/removed states intentionally show no action row at all — no
            // reserved empty space, matching requirement 6.
            EmptyView()
        }
    }

    /// Preferred, full-width layout: labeled buttons. Complete Task reads as primary when a
    /// next task exists (it's the more specific, more common action); otherwise Mark Complete
    /// is primary.
    private var labeledActionRow: some View {
        HStack(spacing: 8) {
            if let nextTaskID = state.nextTaskID {
                Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                    Label("Complete Task", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                if state.canSnoozeNextTask {
                    Button(intent: SnoozeTaskIntent(taskID: nextTaskID)) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Snooze Task")
                }

                Spacer(minLength: 4)

                Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                    Label("Mark Complete", systemImage: "flag.checkered")
                }
                .buttonStyle(.bordered)
            } else {
                Spacer(minLength: 0)

                Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                    Label("Mark Complete", systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
        }
        .font(.caption2)
        .controlSize(.small)
    }

    /// Fallback for narrow Lock Screens: same actions, icon-only, so nothing clips and nothing
    /// contextually valid gets hidden — VoiceOver still gets the full label via
    /// `.accessibilityLabel`.
    private var iconOnlyActionRow: some View {
        HStack(spacing: 10) {
            if let nextTaskID = state.nextTaskID {
                Button(intent: CompleteTaskIntent(taskID: nextTaskID)) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .accessibilityLabel("Complete Task")

                if state.canSnoozeNextTask {
                    Button(intent: SnoozeTaskIntent(taskID: nextTaskID)) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Snooze Task")
                }

                Spacer(minLength: 4)

                Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                    Image(systemName: "flag.checkered")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Mark Complete")
            } else {
                Spacer(minLength: 0)

                Button(intent: CompleteEventIntent(eventID: attributes.eventID)) {
                    Image(systemName: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .accessibilityLabel("Mark Complete")
            }
        }
        .controlSize(.small)
    }

    // MARK: - Background (requirement 5) / Always-On (requirement 7)

    /// `.activityBackgroundTint(_:)` takes a single `Color` that ActivityKit composites over
    /// its own Lock Screen materials — so "layering" the accent over a neutral background
    /// means handing it a low-opacity accent color rather than an opaque one; the system's own
    /// dark material shows through underneath, giving "a dark neutral card with a subtle color
    /// identity" instead of a flat, loud fill. Reduced luminance (Always-On) cuts the opacity
    /// further per requirement 7 rather than relying on the tint color to still read correctly
    /// at that display's very limited color range.
    private var backgroundTint: Color {
        let opacity = isLuminanceReduced ? 0.06 : 0.14
        return EventTypeAccent.color(for: attributes.eventType).opacity(opacity)
    }
}
