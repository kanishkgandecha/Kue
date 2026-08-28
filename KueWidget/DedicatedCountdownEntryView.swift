//
//  DedicatedCountdownEntryView.swift
//  KueWidget
//
//  See docs/22-expanded-and-dedicated-widgets.md "E. Dedicated layouts" — one family-specific
//  view per supported `WidgetFamily`, all reading the same `DedicatedWidgetResolution`. No
//  family recomputes date math or re-fetches anything; every value here already came from
//  `WidgetContentService`/`DedicatedWidgetContentService` (Shared/).
//
//  Tap targets: the whole widget deep-links via `.widgetURL` (requirement I.5/6) — to the
//  selected event's own Detail screen while it's still a real row (tracking or
//  cancelled/skipped), or to an honest explanation screen once it's genuinely `.unavailable`
//  (deleted/never configured) — see `KueDeepLink`/docs/22 "E." for why an in-widget button
//  can never actually reconfigure *this* placed instance. Accessory families (Lock Screen/
//  StandBy) get the same `.widgetURL` but no `Button(intent:)` controls — per-family
//  interactive-button support is inconsistent enough across those families that this phase
//  deliberately omits them there rather than ship an unreliable one (documented omission,
//  requirement I's own "implement only supported interactions and document any omissions").
//

import SwiftUI
import WidgetKit
import AppIntents

struct DedicatedCountdownEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DedicatedCountdownEntry

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch entry.content {
        case .storeUnavailable:
            unavailableBody(title: "Unavailable", message: "Open Kue to refresh.", symbol: "exclamationmark.triangle")
                .widgetURL(KueDeepLink.url(for: .dedicatedCountdownHelp))
        case .resolved(let resolution):
            resolvedBody(resolution)
        }
    }

    @ViewBuilder
    private func resolvedBody(_ resolution: DedicatedWidgetResolution) -> some View {
        switch resolution {
        case .tracking(let content):
            TrackingBody(content: content, family: family)
                .widgetURL(KueDeepLink.url(for: .event(content.eventID)))
        case .cancelled(let eventID, let eventTitle):
            TerminalBody(eventTitle: eventTitle, stateLabel: "Cancelled", symbol: "xmark.circle", family: family)
                .widgetURL(KueDeepLink.url(for: .event(eventID)))
        case .skipped(let eventID, let eventTitle):
            TerminalBody(eventTitle: eventTitle, stateLabel: "Skipped", symbol: "arrow.uturn.forward.circle", family: family)
                .widgetURL(KueDeepLink.url(for: .event(eventID)))
        case .unavailable:
            unavailableBody(title: "Choose an Event", message: "Long-press this widget and choose Edit Widget.", symbol: "questionmark.circle")
                .widgetURL(KueDeepLink.url(for: .dedicatedCountdownHelp))
        }
    }

    @ViewBuilder
    private func unavailableBody(title: String, message: String, symbol: String) -> some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularStateView(symbol: symbol, label: title)
        case .accessoryRectangular:
            AccessoryRectangularStateView(title: title, message: message)
        case .accessoryInline:
            Text("\(Image(systemName: symbol)) \(title)")
        default:
            EmptyStateView(title: title, message: message, symbol: symbol)
        }
    }
}

// MARK: - Tracking (normal, completed, or archived phase)

private struct TrackingBody: View {
    let content: WidgetDisplayContent
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularTrackingView(content: content)
        case .accessoryRectangular:
            AccessoryRectangularTrackingView(content: content)
        case .accessoryInline:
            Text("\(content.eventTitle) · \(WidgetAccessoryLabels.accessorySafeStatus(phase: content.phase, subline: content.subline))")
        case .systemLarge:
            LargeTrackingView(content: content)
        default: // .systemSmall, .systemMedium
            CompactTrackingView(content: content, family: family)
        }
    }
}

/// Small and Medium — E's own spec is nearly identical between them (title, countdown, date/
/// status); Medium adds the full date line and an optional next-task/preparation-progress row
/// where the extra width earns it, rather than a second, differently-organized layout.
private struct CompactTrackingView: View {
    let content: WidgetDisplayContent
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.eventTypeDisplayName.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(content.eventTitle)
                .font(family == .systemSmall ? .headline : .title3)
                .fontWeight(.semibold)
                .foregroundStyle(content.isUrgent ? Color.red : Color.primary)
                .lineLimit(2)
            if let subline = content.subline {
                Text(subline)
                    .font(family == .systemSmall ? .title2 : .title)
                    .fontWeight(.bold)
                    .foregroundStyle(content.isUrgent ? Color.red : Color.secondary)
            }
            if family == .systemMedium, content.tasksTotal > 0 {
                Spacer(minLength: 0)
                ProgressView(value: Double(content.tasksCompleted), total: Double(content.tasksTotal))
                    .tint(.accentColor)
                Text("\(content.tasksCompleted) of \(content.tasksTotal) tasks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
            }
            if showsMarkCompleteButton {
                Button(intent: CompleteEventIntent(eventID: content.eventID)) {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(content.isUrgent ? .red : .accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(content.isUrgent ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary), for: .widget)
    }

    private var showsMarkCompleteButton: Bool {
        // Kue 2.0 Phase 10.1 — docs/25 "F.": never a one-tap complete for an unconfirmed
        // outcome. No separate "Confirm Outcome" control is needed here specifically — the
        // whole widget already deep-links to Event Detail via `.widgetURL` (this file's own
        // header), and `displayContent`'s "Needs Review" subline already says why.
        content.phase != .completed && content.phase != .removed && content.phase != .awaitingOutcome
    }
}

/// Large — E's spec: title/type, prominent countdown, full date/time, preparation progress,
/// a concise list of upcoming incomplete tasks, completed-task count. Deliberately read-only
/// beyond the one "Mark Complete" action — a full per-task checklist here would be
/// reproducing Event Detail in miniature, which requirement E explicitly rules out.
private struct LargeTrackingView: View {
    let content: WidgetDisplayContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if content.isUrgent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(content.eventTypeDisplayName.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(content.eventTitle)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(content.isUrgent ? Color.red : Color.primary)
                .lineLimit(2)

            if let subline = content.subline {
                Text(subline)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(content.isUrgent ? Color.red : Color.secondary)
            }

            if content.tasksTotal > 0 {
                ProgressView(value: Double(content.tasksCompleted), total: Double(content.tasksTotal))
                    .tint(.accentColor)
                Text("\(content.tasksCompleted) of \(content.tasksTotal) tasks completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let upcoming = content.tasks.filter { !$0.isCompleted }.prefix(4)
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(upcoming)) { task in
                        HStack(spacing: 6) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(task.offsetLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(task.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Kue 2.0 Phase 10.1 — docs/25 "F." — same reasoning as `CompactTrackingView`'s
            // own `showsMarkCompleteButton`.
            if content.phase != .completed && content.phase != .removed && content.phase != .awaitingOutcome {
                Button(intent: CompleteEventIntent(eventID: content.eventID)) {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(content.isUrgent ? .red : .accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(content.isUrgent ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary), for: .widget)
    }
}

// MARK: - Terminal states (cancelled/skipped) — small/medium/large + accessory

private struct TerminalBody: View {
    let eventTitle: String
    let stateLabel: String
    let symbol: String
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularStateView(symbol: symbol, label: "\(eventTitle): \(stateLabel)")
        case .accessoryRectangular:
            AccessoryRectangularStateView(title: eventTitle, message: stateLabel)
        case .accessoryInline:
            Text("\(Image(systemName: symbol)) \(eventTitle) · \(stateLabel)")
        default:
            EmptyStateView(title: stateLabel, message: "\"\(eventTitle)\" — long-press and Edit Widget to choose another.", symbol: symbol)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
