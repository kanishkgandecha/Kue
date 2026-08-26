//
//  KueWidgetEntryView.swift
//  KueWidget
//
//  Small + medium rendering for all five widget types — docs/07-widget-engine.md "Widget
//  types (V1)". Family is chosen by the user, supplied via `\.widgetFamily`, never app-owned
//  data. `urgent` is a treatment layered on top of whichever type/phase applies, never its
//  own case. No interactive buttons yet (Phase 9).
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
            header
            Text(content.headline)
                .font(family == .systemSmall ? .headline : .title3)
                .fontWeight(.semibold)
                .foregroundStyle(content.isUrgent ? Color.red : Color.primary)
                .lineLimit(2)

            body(for: content.widgetType)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(content.isUrgent ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary), for: .widget)
    }

    private var header: some View {
        HStack(spacing: 4) {
            if content.isUrgent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Text(content.eventTypeDisplayName.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// docs/07-widget-engine.md "Widget types (V1)" — layout/copy rules per type. All five
    /// share the headline above; this is what makes each type visually distinct.
    @ViewBuilder
    private func body(for widgetType: WidgetType) -> some View {
        switch widgetType {
        case .countdown:
            if let subline = content.subline {
                Text(subline)
                    .font(family == .systemSmall ? .title2 : .title)
                    .fontWeight(.bold)
                    .foregroundStyle(content.isUrgent ? Color.red : Color.secondary)
            }
        case .preparation:
            if let subline = content.subline {
                Label(subline, systemImage: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 1 : 2)
            }
        case .timeline:
            TimelineRows(tasks: content.tasks, family: family)
        case .progress:
            ProgressBody(completed: content.tasksCompleted, total: content.tasksTotal)
        case .checklist:
            ChecklistRows(tasks: content.tasks, family: family)
        }
    }
}

private struct TimelineRows: View {
    let tasks: [WidgetTaskSummary]
    let family: WidgetFamily

    var body: some View {
        let visible = tasks.prefix(family == .systemSmall ? 2 : 3)
        if visible.isEmpty {
            Text("No timeline yet").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { task in
                    HStack(spacing: 4) {
                        Text(task.offsetLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(task.title)
                            .font(.caption)
                            .strikethrough(task.isCompleted)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct ProgressBody: View {
    let completed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                .tint(.accentColor)
            Text("\(completed) / \(total) tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChecklistRows: View {
    let tasks: [WidgetTaskSummary]
    let family: WidgetFamily

    var body: some View {
        let visible = tasks.prefix(family == .systemSmall ? 2 : 4)
        if visible.isEmpty {
            Text("No tasks yet").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { task in
                    HStack(spacing: 4) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(task.isCompleted ? .green : .secondary)
                        Text(task.title)
                            .font(.caption)
                            .strikethrough(task.isCompleted)
                            .lineLimit(1)
                    }
                }
            }
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
