//
//  KueWidgetEntryView.swift
//  KueWidget
//
//  All six supported families for all five widget types — docs/07-widget-engine.md "Widget
//  types (V1)" and docs/22-expanded-and-dedicated-widgets.md "B." (Kue 2.0 Phase 8 added
//  systemLarge + the three accessory families; small/medium behavior below is unchanged from
//  before Phase 8). Family is chosen by the user, supplied via `\.widgetFamily`, never
//  app-owned data. `urgent` is a treatment layered on top of whichever type/phase applies,
//  never its own case.
//
//  Phase 9 (M8) added interactive buttons, gated to "only context-valid controls" per-type
//  and per-state: `CompleteTaskIntent`/`SnoozeTaskIntent` appear next to a visible task only
//  while it's incomplete (and snooze only while `content.canSnooze`); `CompleteEventIntent`
//  appears only on the whole-event types (Countdown/Progress/Timeline — docs/07 "Exposed on
//  the Countdown/Progress/Timeline widget types... as a single button") and only while the
//  event hasn't already reached `.completed`/`.removed`, since offering "mark complete" on an
//  event that's already finished or archived isn't a context-valid control. Phase 8 keeps
//  this gating unchanged for `.systemLarge`; accessory families offer no interactive buttons
//  at all (see `DedicatedCountdownEntryView`'s own header comment for why — the same decision
//  applies here for the identical reason).
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
            stateView(
                title: "Nothing Coming Up",
                message: "Add an event in Kue to see it here.",
                symbol: "calendar.badge.clock"
            )
        case .storeUnavailable:
            stateView(
                title: "Unavailable",
                message: "Open Kue to refresh.",
                symbol: "exclamationmark.triangle"
            )
        }
    }

    @ViewBuilder
    private func stateView(title: String, message: String, symbol: String) -> some View {
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

private struct EventContentView: View {
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
            SizedBody(content: content, isLarge: true, maxRows: 6)
        default: // .systemSmall, .systemMedium
            SizedBody(content: content, isLarge: false, maxRows: family == .systemSmall ? 2 : 3)
        }
    }
}

/// Small/Medium/Large all share this shape — only `isLarge` (title/countdown sizing +
/// button control size) and `maxRows` (how much of the type-specific body shows) differ.
/// docs/22 "B.": Large shows *more of the same real content* (more task rows), never a
/// differently organized layout invented just to fill space.
private struct SizedBody: View {
    let content: WidgetDisplayContent
    let isLarge: Bool
    let maxRows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 6 : 4) {
            header
            Text(content.headline)
                .font(isLarge ? .title2 : (maxRows == 2 ? .headline : .title3))
                .fontWeight(isLarge ? .bold : .semibold)
                .foregroundStyle(content.isUrgent ? Color.red : Color.primary)
                .lineLimit(2)

            TypeBody(widgetType: content.widgetType, content: content, maxRows: maxRows)

            Spacer(minLength: 0)

            if showsCompleteEventButton {
                Button(intent: CompleteEventIntent(eventID: content.eventID)) {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                        .font(isLarge ? .body : .caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(isLarge ? .small : .mini)
                .tint(content.isUrgent ? .red : .accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(content.isUrgent ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary), for: .widget)
    }

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
                    .font(isLarge ? .caption : .caption2)
                    .foregroundStyle(.red)
            }
            Text(content.eventTypeDisplayName.uppercased())
                .font(isLarge ? .caption : .caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// docs/07-widget-engine.md "Widget types (V1)" — layout/copy rules per type. All five share
/// the headline `SizedBody` already renders above this; this is what makes each type
/// visually distinct, at whatever `maxRows` the caller (Small/Medium/Large) allows.
private struct TypeBody: View {
    let widgetType: WidgetType
    let content: WidgetDisplayContent
    let maxRows: Int

    var body: some View {
        switch widgetType {
        case .countdown:
            if let subline = content.subline {
                Text(subline)
                    .font(maxRows <= 2 ? .title2 : .title)
                    .fontWeight(.bold)
                    .foregroundStyle(content.isUrgent ? Color.red : Color.secondary)
            }
        case .preparation:
            // docs/07-widget-engine.md "Preparation — today's task alongside the upcoming
            // event." `content.tasks` is already sorted soonest-due-first, so the first
            // incomplete one *is* "today's task."
            if let nextTask = content.tasks.first(where: { !$0.isCompleted }) {
                TaskRow(task: nextTask, canSnooze: content.canSnooze, showsOffsetLabel: true)
                if maxRows > 3 {
                    let remaining = content.tasks.filter { !$0.isCompleted && $0.id != nextTask.id }.prefix(maxRows - 1)
                    ForEach(Array(remaining)) { task in
                        TaskRow(task: task, canSnooze: content.canSnooze, showsOffsetLabel: true)
                    }
                }
            } else if let subline = content.subline {
                Label(subline, systemImage: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(maxRows <= 2 ? 1 : 2)
            }
        case .timeline:
            TimelineRows(tasks: content.tasks, maxRows: maxRows)
        case .progress:
            ProgressBody(completed: content.tasksCompleted, total: content.tasksTotal, showsUpcoming: maxRows > 3, tasks: content.tasks)
        case .checklist:
            ChecklistRows(tasks: content.tasks, maxRows: maxRows, canSnooze: content.canSnooze)
        }
    }
}

private struct TimelineRows: View {
    let tasks: [WidgetTaskSummary]
    let maxRows: Int

    var body: some View {
        let visible = tasks.prefix(maxRows)
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
    let showsUpcoming: Bool
    let tasks: [WidgetTaskSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                .tint(.accentColor)
            Text("\(completed) / \(total) tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
            // docs/22 "B.": Large uses the extra room for a concise upcoming-task preview
            // rather than just a bigger bar — real additional information, not a stretch.
            if showsUpcoming {
                let upcoming = tasks.filter { !$0.isCompleted }.prefix(3)
                ForEach(Array(upcoming)) { task in
                    HStack(spacing: 4) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
                        Text(task.title).font(.caption2).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct ChecklistRows: View {
    let tasks: [WidgetTaskSummary]
    let maxRows: Int
    let canSnooze: Bool

    var body: some View {
        let visible = tasks.prefix(maxRows)
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
/// Preparation's task row(s).
private struct TaskRow: View {
    let task: WidgetTaskSummary
    let canSnooze: Bool
    /// Preparation shows the offset ("2 days before") next to the title; Checklist doesn't
    /// (its rows are already dense at max row count).
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
