//
//  LiveActivityDynamicIslandViews+Previews.swift
//  KueWidget
//
//  `#Preview` fixtures for every Dynamic Island region in `LiveActivityDynamicIslandViews.swift`.
//  Deterministic value literals only — no SwiftData/ModelContext, nothing touches a real store.
//  One `#Preview` per fixture, each rendering all seven region views stacked so a single canvas
//  entry shows the whole redesign for that state.
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
    tasksCompleted: Int = 0,
    tasksTotal: Int = 0,
    nextTaskID: UUID? = nil,
    remainingTaskCount: Int = 0,
    terminal: ContentState.Terminal? = nil
) -> ContentState {
    ContentState(
        displayTitle: title,
        eventTypeDisplayName: typeDisplayName,
        phase: phase,
        isUrgent: isUrgent,
        effectiveStartDate: .now,
        effectiveEndDate: .now.addingTimeInterval(3600),
        countdownSubline: countdownSubline,
        tasksCompleted: tasksCompleted,
        tasksTotal: tasksTotal,
        nextTaskID: nextTaskID,
        nextTaskSummary: nil,
        remainingTaskCount: remainingTaskCount,
        canSnoozeNextTask: false,
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

/// All seven region views for one fixture, stacked so one canvas entry shows the redesign end
/// to end — at Dynamic Island's own scale (~300pt wide when expanded).
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
                    LiveActivityCompactTrailing(state: state)
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

#Preview("Exam · preparation tasks") {
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
            remainingTaskCount: 3
        )
    )
}

#Preview("Very long title · urgent countdown") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .interview),
        state: previewState(
            title: "Second-Round Interview With the Entire Platform Engineering Leadership Team",
            typeDisplayName: "Interview",
            phase: .countdown,
            isUrgent: true,
            countdownSubline: "12 days",
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(),
            remainingTaskCount: 2
        )
    )
}

#Preview("Trip · no tasks") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .trip),
        state: previewState(
            title: "Flight to Denver",
            typeDisplayName: "Trip",
            phase: .today,
            countdownSubline: "Today"
        )
    )
}

#Preview("Awaiting outcome") {
    DynamicIslandFixturePreview(
        attributes: previewAttributes(eventType: .deadline),
        state: previewState(
            title: "Grant Application",
            typeDisplayName: "Deadline",
            phase: .awaitingOutcome,
            countdownSubline: nil
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
