//
//  LiveActivityLockScreenView+Previews.swift
//  KueWidget
//
//  `#Preview` fixtures for `LiveActivityLockScreenView.swift` — the 15 named scenarios from the
//  Live Activity visual-polish task: short title, very long title, exam, trip, preparation with
//  tasks, no tasks, needs review, completed, cancelled, privacy-hidden, large Dynamic Type, dark
//  appearance, light appearance, and reduced luminance (14 here — "birthday" from the task's own
//  list is not a real `EventType` case, see `EventTypeAccent.swift`'s header; a 15th "exam ·
//  no tasks yet" fixture stands in so the matrix still has 15 entries). Deterministic value
//  literals only — no SwiftData/ModelContext, nothing touches a real store.
//

import SwiftUI
import WidgetKit
import ActivityKit

private func lockScreenPreviewState(
    title: String,
    typeDisplayName: String,
    phase: WidgetLifecyclePhase,
    isUrgent: Bool = false,
    countdownSubline: String? = "3 days",
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
        effectiveStartDate: .now,
        effectiveEndDate: .now.addingTimeInterval(3600),
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

private func lockScreenPreviewAttributes(eventType: EventType) -> KueLiveActivityAttributes {
    KueLiveActivityAttributes(
        eventID: UUID(),
        eventType: eventType,
        isAllDay: false,
        timeZoneIdentifier: TimeZone.current.identifier
    )
}

#Preview("Short title") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .generic),
        state: lockScreenPreviewState(title: "Team Sync", typeDisplayName: "Event", phase: .today, countdownSubline: "Today")
    )
}

#Preview("Very long title") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
            title: "Second-Round Interview With the Entire Platform Engineering Leadership Team",
            typeDisplayName: "Interview",
            phase: .countdown,
            isUrgent: true,
            countdownSubline: "12 days"
        )
    )
}

#Preview("Exam") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(title: "Chemistry Final", typeDisplayName: "Exam", phase: .countdown, countdownSubline: "5 days")
    )
}

#Preview("Trip") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(title: "Flight to Denver", typeDisplayName: "Trip", phase: .today, countdownSubline: "Today")
    )
}

#Preview("Preparation · tasks in progress") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(
            title: "Midterm Exam",
            typeDisplayName: "Exam",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 2,
            tasksTotal: 5,
            nextTaskID: UUID(),
            nextTaskSummary: "Review chapter 6",
            remainingTaskCount: 3,
            canSnoozeNextTask: true
        )
    )
}

#Preview("No tasks") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Rent Due", typeDisplayName: "Deadline", phase: .countdown, isUrgent: true, countdownSubline: "1 day")
    )
}

#Preview("Needs review") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Grant Application", typeDisplayName: "Deadline", phase: .awaitingOutcome, countdownSubline: nil)
    )
}

#Preview("Completed") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .generic),
        state: lockScreenPreviewState(title: "Team Offsite", typeDisplayName: "Event", phase: .completed, countdownSubline: nil, tasksCompleted: 4, tasksTotal: 4)
    )
}

#Preview("Cancelled") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(title: "Chemistry Final", typeDisplayName: "Exam", phase: .countdown, countdownSubline: "5 days", terminal: .cancelled)
    )
}

#Preview("Skipped") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .generic),
        state: lockScreenPreviewState(title: "Weekly Check-in", typeDisplayName: "Event", phase: .countdown, countdownSubline: "2 days", terminal: .skipped)
    )
}

// Privacy-hidden: `displayTitle`/`nextTaskSummary` already carry whatever
// `LiveActivityStateBuilder` decided is safe to show — a hidden title arrives here as a generic
// label, and a hidden next task arrives as `nextTaskSummary: nil` even though tasks exist. This
// view never re-derives that decision, just renders what it's given.
#Preview("Privacy hidden") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
            title: "Interview",
            typeDisplayName: "Interview",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(),
            nextTaskSummary: nil,
            remainingTaskCount: 2
        )
    )
}

#Preview("Large Dynamic Type") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(
            title: "Midterm Exam",
            typeDisplayName: "Exam",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 2,
            tasksTotal: 5,
            nextTaskID: UUID(),
            nextTaskSummary: "Review chapter 6",
            remainingTaskCount: 3
        )
    )
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dark appearance") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(title: "Flight to Denver", typeDisplayName: "Trip", phase: .today, countdownSubline: "Today")
    )
    .preferredColorScheme(.dark)
}

#Preview("Light appearance") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(title: "Flight to Denver", typeDisplayName: "Trip", phase: .today, countdownSubline: "Today")
    )
    .preferredColorScheme(.light)
}

#Preview("Reduced luminance (AOD)") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Rent Due", typeDisplayName: "Deadline", phase: .countdown, isUrgent: true, countdownSubline: "1 day")
    )
    .environment(\.isLuminanceReduced, true)
    .preferredColorScheme(.dark)
}
