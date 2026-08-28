//
//  WidgetAccessoryViews.swift
//  KueWidget
//
//  Lock Screen / StandBy accessory rendering shared between `KueWidget` and
//  `DedicatedCountdownWidget` — both kinds render from the identical `WidgetDisplayContent`
//  shape, so their `.accessoryCircular`/`.accessoryRectangular` views are the same code, not
//  two parallel implementations (docs/22-expanded-and-dedicated-widgets.md "J.": "do not
//  duplicate ... status logic across widget-family views"). These can't live in `Shared/`
//  (they use `.containerBackground(_:for: .widget)`, a WidgetKit-only API, and `Shared/` also
//  compiles into the Kue app and KueShare targets, neither of which link WidgetKit) — this
//  file is the widget-extension-only equivalent of that sharing.
//
//  Every label below reads `WidgetAccessoryLabels.accessorySafeStatus(phase:subline:)`,
//  never `content.subline` directly — docs/22 "H. Privacy": `subline` carries a task title
//  (`.preparation`/`.tomorrow`) or the event's location (`.today`) for those phases, exactly
//  the content that must never reach an ambient-visible Lock Screen/StandBy surface.
//

import SwiftUI
import WidgetKit

/// One concise value — docs/22 "E.": "93d," "6h," or a completion mark. Color is never the
/// only signal: the accessibility label always carries the full meaning.
struct AccessoryCircularTrackingView: View {
    let content: WidgetDisplayContent

    private var status: String { WidgetAccessoryLabels.accessorySafeStatus(phase: content.phase, subline: content.subline) }

    var body: some View {
        Group {
            if content.phase == .completed || content.phase == .removed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
            } else if content.phase == .awaitingOutcome {
                // Kue 2.0 Phase 10.1 — docs/25 "F.": never the checkmark (that would falsely
                // imply confirmed completion), and a progress gauge is moot once the event has
                // already passed — just the "Needs Review" status word.
                Text(status)
                    .font(.headline)
            } else if content.tasksTotal > 0 {
                Gauge(value: Double(content.tasksCompleted), in: 0...Double(max(content.tasksTotal, 1))) {
                    Text(status)
                } currentValueLabel: {
                    Text(status).font(.caption2)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Text(status)
                    .font(.headline)
            }
        }
        .widgetAccentable()
        .accessibilityLabel("\(content.eventTitle): \(status)")
        .containerBackground(.clear, for: .widget)
    }
}

struct AccessoryCircularStateView: View {
    let symbol: String
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title2)
            .widgetAccentable()
            .accessibilityLabel(label)
            .containerBackground(.clear, for: .widget)
    }
}

/// Short title + concise countdown/status — docs/22 "E.": "avoid truncating the essential
/// value" (the countdown/status line, not the title, is what must never be cut).
struct AccessoryRectangularTrackingView: View {
    let content: WidgetDisplayContent

    private var status: String { WidgetAccessoryLabels.accessorySafeStatus(phase: content.phase, subline: content.subline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(content.eventTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .widgetAccentable()
        .accessibilityLabel("\(content.eventTitle): \(status)")
        .containerBackground(.clear, for: .widget)
    }
}

struct AccessoryRectangularStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .widgetAccentable()
        .containerBackground(.clear, for: .widget)
    }
}
