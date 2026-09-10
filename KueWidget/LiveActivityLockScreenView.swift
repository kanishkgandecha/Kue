//
//  LiveActivityLockScreenView.swift
//  KueWidget
//
//  Kue 3.0 Phase 2 rebuild (docs/30-kue-3-live-activities-and-dynamic-island.md) — a real-device
//  screenshot showed the Post-Phase-12 color-only fix (docs/23 "M.") still clipped: a crowded
//  three-button row, and a Kue wordmark that could contest space with the status label at
//  small widths/large Dynamic Type. This rebuild replaces the single fixed layout with three
//  explicit, strictly-budgeted tiers (Full/Compact/Minimal) chosen by `ViewThatFits` — degrading
//  content, never shrinking type past readability. See docs/30 "Content budgets"/"Adaptive
//  tiers" for the exact rule this file implements. No lifecycle policy is (re)derived here —
//  `phase`/`terminal`/`isUrgent` all arrive already computed on `ContentState`, and which
//  action(s) apply comes from `LiveActivityActionPolicy.plan(for:eventID:)` (Shared/), the one
//  shared decision layer this file and `LiveActivityDynamicIslandViews.swift` both read.
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
    private var plan: LiveActivityActionPlan { LiveActivityActionPolicy.plan(for: state, eventID: attributes.eventID) }
    /// Full tier's "Next: …" line only makes sense while Complete Task is actually the
    /// available primary action — otherwise there's no control that line would be describing.
    private var nextTaskLine: String? {
        guard case .completeTask = plan.primary else { return nil }
        if let summary = state.nextTaskSummary { return "Next: \(summary)" }
        if state.nextTaskID != nil { return "Next task" } // privacy-hidden title, id still present
        return nil
    }
    private var showsTaskProgress: Bool { state.terminal == nil && state.tasksTotal > 0 }

    var body: some View {
        ViewThatFits {
            fullTier
            compactTier
            minimalTier
        }
        .padding(.vertical, 2)
        .activityBackgroundTint(backgroundTint)
        .activitySystemActionForegroundColor(.primary)
    }

    // MARK: - Full tier (docs/30 "Full tier")

    private var fullTier: some View {
        VStack(alignment: .leading, spacing: 6) {
            fullHeader
            fullMainContent
            if showsTaskProgress {
                fullProgressRow
            }
            fullActionsRow
        }
    }

    /// Branding is the first thing this rebuild drops under pressure (docs/30 content-priority
    /// order: branding is dead last) — `KueMark` only ever renders in this Full tier;
    /// `ViewThatFits` removes the whole tier, wordmark included, the moment it doesn't fit,
    /// rather than letting the mark itself clip.
    private var fullHeader: some View {
        HStack {
            Label(state.eventTypeDisplayName.uppercased(), systemImage: statusSymbol(state))
                .font(.caption2)
                .foregroundStyle(state.isUrgent && state.terminal == nil ? .red : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            KueMark()
            Text(statusLine(state))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(accent)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
    }

    private var fullMainContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.8) // no clipping at extreme Dynamic Type
            if let nextTaskLine {
                Text(nextTaskLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var fullProgressRow: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(state.tasksCompleted), total: Double(state.tasksTotal))
                .progressViewStyle(.linear)
                .tint(accent)
            Text("\(state.tasksCompleted) of \(state.tasksTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var fullActionsRow: some View {
        if plan.primary != nil || plan.secondary != nil {
            HStack(spacing: 8) {
                if let primary = plan.primary {
                    actionControl(primary, style: .full)
                        .buttonStyle(.borderedProminent)
                        .tint(primaryActionTint(for: primary, accent: accent))
                }
                Spacer(minLength: 4)
                if let secondary = plan.secondary {
                    actionControl(secondary, style: .full)
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption2)
            .controlSize(.small)
        }
    }

    // MARK: - Compact tier (docs/30 "Compact tier")

    private var compactTier: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(compactCountdown)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if showsTaskProgress {
                Text("\(state.tasksCompleted) of \(state.tasksTotal) tasks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            compactActionsRow
        }
    }

    @ViewBuilder
    private var compactActionsRow: some View {
        if plan.primary != nil || plan.secondary != nil {
            HStack(spacing: 8) {
                if let primary = plan.primary {
                    actionControl(primary, style: .compact)
                        .buttonStyle(.borderedProminent)
                        .tint(primaryActionTint(for: primary, accent: accent))
                }
                Spacer(minLength: 4)
                if let secondary = plan.secondary {
                    actionControl(secondary, style: .iconOnly)
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption2)
            .controlSize(.mini)
        }
    }

    // MARK: - Minimal fallback (docs/30 "Minimal fallback")

    /// The system provides very constrained space here — title and a compact countdown only,
    /// no progress, no actions. Still never empty: a title always exists (real or the generic
    /// privacy-hidden label), and the countdown/state word always resolves to something.
    private var minimalTier: some View {
        HStack {
            Text(state.displayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(compactCountdown)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(accent)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var compactCountdown: String { LiveActivityCompactCountdown.label(for: state) }

    // MARK: - Background / Always-On

    /// `.activityBackgroundTint(_:)` takes a single `Color` that ActivityKit composites over
    /// its own Lock Screen materials — a low-opacity accent reads as "a dark neutral card with
    /// a subtle color identity" rather than a flat, loud fill (docs/23 "M." — unchanged by this
    /// rebuild, which only restructures content, not the color system). Reduced luminance
    /// (Always-On) cuts the opacity further so the tint never overpowers AOD's limited range.
    private var backgroundTint: Color {
        let opacity = isLuminanceReduced ? 0.06 : 0.14
        return EventTypeAccent.color(for: attributes.eventType).opacity(opacity)
    }
}
