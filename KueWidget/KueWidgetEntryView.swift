//
//  KueWidgetEntryView.swift
//  KueWidget
//
//  Small + medium rendering for all five widget types — docs/07-widget-engine.md "Widget
//  types (V1)". Family is chosen by the user, supplied via `\.widgetFamily`, never app-owned
//  data. `urgent` is a treatment layered on top of whichever type/phase applies, never its
//  own case.
//
//  Phase 9 (M8) added interactive buttons, gated to "only context-valid controls" per-type
//  and per-state: `CompleteTaskIntent`/`SnoozeTaskIntent` appear next to a visible task only
//  while it's incomplete (and snooze only while `content.canSnooze`); `CompleteEventIntent`
//  appears only on the whole-event types (Countdown/Progress/Timeline — docs/07 "Exposed on
//  the Countdown/Progress/Timeline widget types... as a single button") and only while the
//  event hasn't already reached `.completed`/`.removed`, since offering "mark complete" on an
//  event that's already finished or archived isn't a context-valid control.
//

import SwiftUI
import WidgetKit
import AppIntents

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

            if showsCompleteEventButton {
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

    /// docs/07-widget-engine.md "CompleteEventIntent" — the whole-event types only, and only
    /// while there's still something meaningful to mark complete.
    private var showsCompleteEventButton: Bool {
        guard content.widgetType == .countdown || content.widgetType == .progress || content.widgetType == .timeline else {
            return false
        }
        return content.phase != .completed && content.phase != .removed
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
            // docs/07-widget-engine.md "Preparation — today's task alongside the upcoming
            // event." `content.tasks` is already sorted soonest-due-first, so the first
            // incomplete one *is* "today's task" — the same row `CompleteTaskIntent`/
            // `SnoozeTaskIntent` are documented to appear on ("per-visible-task button").
            if let nextTask = content.tasks.first(where: { !$0.isCompleted }) {
                TaskRow(task: nextTask, canSnooze: content.canSnooze, showsOffsetLabel: true)
            } else if let subline = content.subline {
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
            ChecklistRows(tasks: content.tasks, family: family, canSnooze: content.canSnooze)
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
    let canSnooze: Bool

    var body: some View {
        let visible = tasks.prefix(family == .systemSmall ? 2 : 4)
        if visible.isEmpty {
            Text("No tasks yet").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { task in
                    TaskRow(task: task, canSnooze: canSnooze, showsOffsetLabel: false)
                }
            }
        }
    }
}

/// One task, with its interactive controls — docs/07-widget-engine.md "CompleteTaskIntent"
/// (per-visible-task button) / "SnoozeTaskIntent" (secondary button alongside it, hidden —
/// not disabled — once `canSnooze` is false). Shared between Checklist's multi-row list and
/// Preparation's single "today's task" row.
private struct TaskRow: View {
    let task: WidgetTaskSummary
    let canSnooze: Bool
    /// Preparation shows the offset ("2 days before") next to the title; Checklist doesn't
    /// (its rows are already dense with up to 4 tasks).
    let showsOffsetLabel: Bool

    var body: some View {
        HStack(spacing: 4) {
            if task.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(intent: CompleteTaskIntent(taskID: task.id)) {
                    Image(systemName: "circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if showsOffsetLabel {
                Text(task.offsetLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(task.title)
                .font(.caption)
                .strikethrough(task.isCompleted)
                .lineLimit(1)

            if !task.isCompleted && canSnooze {
                Spacer(minLength: 4)
                Button(intent: SnoozeTaskIntent(taskID: task.id)) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
