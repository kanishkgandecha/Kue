//
//  LiveActivityLockScreenView+Previews.swift
//  KueWidget
//
//  Kue 3.0 Phase 2 (docs/30) — the preview matrix that rebuild's spec calls for: short/very
//  long title, zero/one/multiple tasks, three-digit day countdown, hours countdown, starting
//  now, in progress, needs review, completed, cancelled, privacy-hidden title, privacy-hidden
//  task, light/dark appearance, large Dynamic Type, reduced luminance. Deterministic value
//  literals only — no SwiftData/ModelContext, nothing touches a real store. `effectiveStartDate`/
//  `effectiveEndDate` are set relative to `.now` per fixture so `LiveActivityCompactCountdown`
//  (Shared/) — read by the Compact/Minimal tiers this file exercises — produces the specific
//  countdown word each preview names itself after, not just the Full tier's own
//  `countdownSubline` text.
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
        state: lockScreenPreviewState(title: "Team Sync", typeDisplayName: "Event", phase: .today, countdownSubline: "Today", effectiveStartDate: .now.addingTimeInterval(1800), effectiveEndDate: .now.addingTimeInterval(5400))
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
            countdownSubline: "12 days",
            effectiveStartDate: .now.addingTimeInterval(12 * 86_400)
        )
    )
}

#Preview("Zero tasks") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Rent Due", typeDisplayName: "Deadline", phase: .countdown, isUrgent: true, countdownSubline: "1 day", effectiveStartDate: .now.addingTimeInterval(86_400))
    )
}

#Preview("One incomplete task") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(
            title: "Chemistry Final",
            typeDisplayName: "Exam",
            phase: .preparation,
            countdownSubline: "5 days",
            effectiveStartDate: .now.addingTimeInterval(5 * 86_400),
            tasksCompleted: 0,
            tasksTotal: 1,
            nextTaskID: UUID(),
            nextTaskSummary: "Review chapter 6",
            remainingTaskCount: 1,
            canSnoozeNextTask: true
        )
    )
}

#Preview("Multiple tasks") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .exam),
        state: lockScreenPreviewState(
            title: "Midterm Exam",
            typeDisplayName: "Exam",
            phase: .preparation,
            countdownSubline: "3 days",
            effectiveStartDate: .now.addingTimeInterval(3 * 86_400),
            tasksCompleted: 2,
            tasksTotal: 6,
            nextTaskID: UUID(),
            nextTaskSummary: "Review chapter 6",
            remainingTaskCount: 4,
            canSnoozeNextTask: true
        )
    )
}

#Preview("Three-digit day countdown") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(
            title: "Trip to Japan",
            typeDisplayName: "Trip",
            phase: .countdown,
            countdownSubline: "128 days",
            effectiveStartDate: .now.addingTimeInterval(128 * 86_400)
        )
    )
}

#Preview("Hours countdown") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
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
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
            title: "Final-Round Interview",
            typeDisplayName: "Interview",
            phase: .today,
            isUrgent: true,
            countdownSubline: "Starting now",
            effectiveStartDate: .now,
            effectiveEndDate: .now.addingTimeInterval(3600)
        )
    )
}

#Preview("In progress") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(
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
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Grant Application", typeDisplayName: "Deadline", phase: .awaitingOutcome, countdownSubline: nil, effectiveEndDate: .now.addingTimeInterval(-3600))
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

#Preview("Missing / store failure") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .generic),
        state: LiveActivityStateBuilder.unavailableContentState(eventType: .generic)
    )
}

// Privacy-hidden: `displayTitle`/`nextTaskSummary` already carry whatever
// `LiveActivityStateBuilder` decided is safe to show — a hidden title arrives here as a generic
// label, and a hidden next task arrives as `nextTaskSummary: nil` even though tasks exist. This
// view never re-derives that decision, just renders what it's given.
#Preview("Privacy hidden · title") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
            title: "Interview", // the generic event-type label `LiveActivityStateBuilder` falls back to
            typeDisplayName: "Interview",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(),
            nextTaskSummary: "Review notes",
            remainingTaskCount: 2
        )
    )
}

#Preview("Privacy hidden · task") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .interview),
        state: lockScreenPreviewState(
            title: "Second-Round Interview",
            typeDisplayName: "Interview",
            phase: .preparation,
            countdownSubline: "3 days",
            tasksCompleted: 1,
            tasksTotal: 3,
            nextTaskID: UUID(), // still present — the Complete Task button must keep working
            nextTaskSummary: nil, // hidden per privacy preference
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
        state: lockScreenPreviewState(title: "Flight to Denver", typeDisplayName: "Trip", phase: .today, countdownSubline: "Today", effectiveStartDate: .now.addingTimeInterval(1800))
    )
    .preferredColorScheme(.dark)
}

#Preview("Light appearance") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .trip),
        state: lockScreenPreviewState(title: "Flight to Denver", typeDisplayName: "Trip", phase: .today, countdownSubline: "Today", effectiveStartDate: .now.addingTimeInterval(1800))
    )
    .preferredColorScheme(.light)
}

#Preview("Reduced luminance (AOD)") {
    LiveActivityLockScreenView(
        attributes: lockScreenPreviewAttributes(eventType: .deadline),
        state: lockScreenPreviewState(title: "Rent Due", typeDisplayName: "Deadline", phase: .countdown, isUrgent: true, countdownSubline: "1 day", effectiveStartDate: .now.addingTimeInterval(86_400))
    )
    .environment(\.isLuminanceReduced, true)
    .preferredColorScheme(.dark)
}
