//
//  KueWidgetEntryView.swift
//  KueWidget
//
//  Small + medium rendering — docs/07-widget-engine.md "Widget types (V1)" says family is
//  chosen by the user, supplied via `\.widgetFamily`, never app-owned data. No interactive
//  buttons yet (Phase 9).
//

import SwiftUI
import WidgetKit

struct KueWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KueWidgetEntry

    var body: some View {
        switch entry.content {
        case .event(let content):
            EventContentView(content: content, family: family)
        case .noEligibleEvent:
            EmptyStateView(
                title: "Nothing Coming Up",
                message: "Add an event in Kue to see it here.",
                symbol: "calendar.badge.clock"
            )
        case .storeUnavailable:
            EmptyStateView(
                title: "Unavailable",
                message: "Open Kue to refresh.",
                symbol: "exclamationmark.triangle"
            )
        }
    }
}

private struct EventContentView: View {
    let content: WidgetDisplayContent
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.eventTypeDisplayName.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(content.headline)
                .font(family == .systemSmall ? .headline : .title3)
                .fontWeight(.semibold)
                .lineLimit(2)
            if let subline = content.subline {
                Text(subline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 1 : 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
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
