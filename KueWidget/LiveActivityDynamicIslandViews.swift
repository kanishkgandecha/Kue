//
//  LiveActivityDynamicIslandViews.swift
//  KueWidget
//
//  Kue 3.0 Phase 2 rebuild (docs/30-kue-3-live-activities-and-dynamic-island.md). Each
//  presentation is rebuilt independently per its own real constraints, rather than reusing the
//  Lock Screen's layout squeezed down — docs/30 "Dynamic Island" is explicit about this.
//  Content: `statusLine`/`statusSymbol`/`activeAccentColor`/`LiveActivityCompactCountdown`
//  (Shared/) are read, never re-derived; which action(s) apply comes from the one shared
//  `LiveActivityActionPolicy.plan(for:eventID:)` this file and the Lock Screen's own file both
//  read — so the two presentations can never disagree about which control shows.
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
                .accessibilityHidden(true) // meaning already carried by the text label below
            Text(state.eventTypeDisplayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.eventTypeDisplayName), \(statusLine(state))")
    }
}

struct LiveActivityDynamicIslandExpandedTrailing: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // Trailing owns the countdown/lifecycle word — the compact form
    // (`LiveActivityCompactCountdown`), tinted with the event accent. Center (below) shows the
    // title only; the state description reads in exactly one place, not two, per docs/30 "Do
    // not repeat the title or countdown in multiple regions."
    var body: some View {
        Text(LiveActivityCompactCountdown.label(for: state))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(statusLine(state))
    }
}

struct LiveActivityDynamicIslandExpandedCenter: View {
    let state: ContentState

    // Title only, per docs/30's own region contract — the countdown/state word already lives
    // in Trailing; repeating it here (even as plain secondary text, the pre-rebuild shape) is
    // exactly the duplication docs/30 rules out.
    var body: some View {
        Text(state.displayTitle)
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct LiveActivityDynamicIslandExpandedBottom: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    private var accent: Color { activeAccentColor(eventType: attributes.eventType, state: state) }
    private var plan: LiveActivityActionPlan { LiveActivityActionPolicy.plan(for: state, eventID: attributes.eventID) }
    private var showsTaskProgress: Bool { state.terminal == nil && state.tasksTotal > 0 }

    // Sits below Leading/Trailing/Center, which already reserve the space the system's own
    // TrueDepth-camera cutout needs at the top of the expanded presentation — this region only
    // ever spans its own row underneath, never anything positioned to collide with it.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTaskProgress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(state.tasksCompleted), total: Double(state.tasksTotal))
                        .tint(accent)
                    Text("\(state.tasksCompleted) of \(state.tasksTotal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
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
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // Compact Trailing is the tightest, highest-contrast-required region in this whole
    // feature — `LiveActivityCompactCountdown` gives it a short, deterministic word ("19d,"
    // "3h," "Now," "Review," "Done") that already accounts for terminal states, not just the
    // old day-count-only compaction. `.monospacedDigit()` keeps a shrinking count from
    // jittering the pill's width; the scale factor guards a 3-digit-or-more case.
    var body: some View {
        Text(LiveActivityCompactCountdown.label(for: state))
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(statusLine(state))
    }
}

struct LiveActivityMinimal: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    // docs/30 "Minimal": icon over text — at this region's fixed circular size, an SF Symbol
    // scales cleanly with zero clipping risk, where any text has none of that margin. A single
    // small tinted icon, no background fill, still carries the event's own accent identity.
    var body: some View {
        Image(systemName: statusSymbol(state))
            .foregroundStyle(activeAccentColor(eventType: attributes.eventType, state: state))
            .accessibilityLabel(statusLine(state))
    }
}
