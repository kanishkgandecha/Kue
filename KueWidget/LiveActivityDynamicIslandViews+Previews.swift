//
//  LiveActivityDynamicIslandViews+Previews.swift
//  KueWidget
//
//  Kue 3.0 Phase 2 (docs/30) — `#Preview` fixtures for every Dynamic Island region. Deterministic
//  value literals only — no SwiftData/ModelContext, nothing touches a real store. One `#Preview`
//  per fixture, each rendering every region (Expanded's four plus Compact Leading/Trailing plus
//  Minimal) stacked so a single canvas entry shows the whole rebuild for that state.
//

import SwiftUI
import WidgetKit
import ActivityKit

private func previewState(
    title: String,
    typeDisplayName: String,
    phase: WidgetLifecyclePhase,
    isUrgent: Bool = false,
    countdownSubline: String? = "3 days",
    effectiveStartDate: Date = .now.addingTimeInterval(3 * 86_400),
    effectiveEndDate: Date = .now.addingTimeInterval(3 * 86_400 + 3600),
    tasksCompleted: Int = 0,
    tasksTotal: Int = 0,
    nextTaskID: UUID? = nil,
    nextTaskSummary: String? = nil,
    remainingTaskCount: Int = 0,
    canSnoozeNextTask: Bool = false,
    terminal: ContentState.Terminal? = nil
) -> ContentState {
    ContentState(
        displayTitle: title,
        eventTypeDisplayName: typeDisplayName,
        phase: phase,
        isUrgent: isUrgent,
        effectiveStartDate: effectiveStartDate,
        effectiveEndDate: effectiveEndDate,
        countdownSubline: countdownSubline,
        tasksCompleted: tasksCompleted,
        tasksTotal: tasksTotal,
        nextTaskID: nextTaskID,
        nextTaskSummary: nextTaskSummary,
        remainingTaskCount: remainingTaskCount,
        canSnoozeNextTask: canSnoozeNextTask,
        terminal: terminal,
        lastUpdated: .now
    )
}

private func previewAttributes(eventType: EventType) -> KueLiveActivityAttributes {
    KueLiveActivityAttributes(
        eventID: UUID(),
        eventType: eventType,
        isAllDay: false,
        timeZoneIdentifier: TimeZone.current.identifier
    )
}

/// Every region for one fixture, stacked so one canvas entry shows the rebuild end to end — at
/// Dynamic Island's own scale (~300pt wide when expanded).
private struct DynamicIslandFixturePreview: View {
    let attributes: KueLiveActivityAttributes
    let state: ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("Expanded").font(.caption).foregroundStyle(.tertiary)
                HStack(alignment: .top) {
                    LiveActivityDynamicIslandExpandedLeading(attributes: attributes, state: state)
                    Spacer()
                    LiveActivityDynamicIslandExpandedCenter(state: state)
                    Spacer()
                    LiveActivityDynamicIslandExpandedTrailing(attributes: attributes, state: state)
                }
                LiveActivityDynamicIslandExpandedBottom(attributes: attributes, state: state)
            }
            Divider()
            Group {
                Text("Compact").font(.caption).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    LiveActivityCompactLeading(attributes: attributes, state: state)
                    LiveActivityCompactTrailing(attributes: attributes, state: state)
                }
                Text("Minimal").font(.caption).foregroundStyle(.tertiary)
                LiveActivityMinimal(attributes: attributes, state: state)
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
        .background(.black)
        .foregroundStyle(.white)
    }
}

#Preview("Exam · preparation, multiple tasks") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .exam),
        state: previewState(
            title: "Midterm Exam",
            typeDisplayName: "Exam",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 2,
            tasksTotal: 5,
            nextTaskID: UUID(),
            remainingTaskCount: 3,
            canSnoozeNextTask: true
        )
    )
}

#Preview("Very long title · urgent, three-digit countdown") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .interview),
        state: previewState(
            title: "Second-Round Interview With the Entire Platform Engineering Leadership Team",
            typeDisplayName: "Interview",
            phase: .countdown,
            isUrgent: true,
            countdownSubline: "128 days",
            effectiveStartDate: .now.addingTimeInterval(128 * 86_400),
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(),
            remainingTaskCount: 2
        )
    )
}

#Preview("Hours countdown · zero tasks") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .interview),
        state: previewState(
            title: "Final-Round Interview",
            typeDisplayName: "Interview",
            phase: .today,
            isUrgent: true,
            countdownSubline: "Today",
            effectiveStartDate: .now.addingTimeInterval(3 * 3600),
            effectiveEndDate: .now.addingTimeInterval(4 * 3600)
        )
    )
}

#Preview("Starting now") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .generic),
        state: previewState(
            title: "Team Sync",
            typeDisplayName: "Event",
            phase: .today,
            countdownSubline: "Starting now",
            effectiveStartDate: .now,
            effectiveEndDate: .now.addingTimeInterval(1800)
        )
    )
}

#Preview("In progress") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .trip),
        state: previewState(
            title: "Flight to Denver",
            typeDisplayName: "Trip",
            phase: .today,
            countdownSubline: "In progress",
            effectiveStartDate: .now.addingTimeInterval(-1800),
            effectiveEndDate: .now.addingTimeInterval(5400)
        )
    )
}

#Preview("Needs review") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .deadline),
        state: previewState(
            title: "Grant Application",
            typeDisplayName: "Deadline",
            phase: .awaitingOutcome,
            countdownSubline: nil,
            effectiveEndDate: .now.addingTimeInterval(-3600)
        )
    )
}

#Preview("Completed") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .generic),
        state: previewState(
            title: "Team Offsite",
            typeDisplayName: "Event",
            phase: .completed,
            countdownSubline: nil,
            tasksCompleted: 4,
            tasksTotal: 4
        )
    )
}

#Preview("Cancelled") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .exam),
        state: previewState(
            title: "Chemistry Final",
            typeDisplayName: "Exam",
            phase: .countdown,
            countdownSubline: "5 days",
            terminal: .cancelled
        )
    )
}

#Preview("Skipped") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .generic),
        state: previewState(
            title: "Weekly Check-in",
            typeDisplayName: "Event",
            phase: .countdown,
            countdownSubline: "2 days",
            terminal: .skipped
        )
    )
}

#Preview("Missing / store failure") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .generic),
        state: LiveActivityStateBuilder.unavailableContentState(eventType: .generic)
    )
}

#Preview("Privacy hidden · title and task") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .interview),
        state: previewState(
            title: "Interview", // generic fallback label — never the real title
            typeDisplayName: "Interview",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(), // still present — Complete Task keeps working
            nextTaskSummary: nil, // hidden
            remainingTaskCount: 2
        )
    )
}
