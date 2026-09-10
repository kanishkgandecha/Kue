//
//  LiveActivityActionSetTests.swift
//  KueTests
//
//  Kue 3.0 Phase 2 (docs/30) rebuild. `LiveActivityActionPolicy.plan(for:eventID:)`
//  (Shared/Services/LiveActivity/LiveActivityActionSet.swift) is the one place the Lock Screen
//  and every Dynamic Island region decide which action(s) apply — these tests are the "at most
//  one primary + one secondary," "terminal states expose no mutation," and "no task ⇒ no
//  Complete Task" coverage docs/30's spec calls for directly.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct LiveActivityActionSetTests {
    private let eventID = UUID()

    private func state(
        phase: WidgetLifecyclePhase,
        nextTaskID: UUID? = nil,
        canSnoozeNextTask: Bool = false,
        terminal: KueLiveActivityAttributes.ContentState.Terminal? = nil
    ) -> KueLiveActivityAttributes.ContentState {
        KueLiveActivityAttributes.ContentState(
            displayTitle: "Fixture Event",
            eventTypeDisplayName: "Event",
            phase: phase,
            isUrgent: false,
            effectiveStartDate: .now,
            effectiveEndDate: .now.addingTimeInterval(3600),
            countdownSubline: "3 days",
            tasksCompleted: 0,
            tasksTotal: 0,
            nextTaskID: nextTaskID,
            nextTaskSummary: nil,
            remainingTaskCount: 0,
            canSnoozeNextTask: canSnoozeNextTask,
            terminal: terminal,
            lastUpdated: .now
        )
    }

    // MARK: - At most one primary + one secondary, for every non-terminal phase

    @Test func genuinelyTrackingWithASnoozableNextTaskOffersCompleteTaskPrimaryAndSnoozeSecondary() {
        let taskID = UUID()
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .preparation, nextTaskID: taskID, canSnoozeNextTask: true), eventID: eventID)
        #expect(plan.primary == .completeTask(taskID: taskID))
        #expect(plan.secondary == .snoozeTask(taskID: taskID))
    }

    @Test func genuinelyTrackingWithANonSnoozableNextTaskOffersCompleteTaskPrimaryAndOpenEventSecondary() {
        let taskID = UUID()
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .countdown, nextTaskID: taskID, canSnoozeNextTask: false), eventID: eventID)
        #expect(plan.primary == .completeTask(taskID: taskID))
        #expect(plan.secondary == .openEvent(eventID: eventID))
    }

    @Test func noTaskProducesNoCompleteTaskActionOnlyMarkCompletePrimary() {
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .countdown, nextTaskID: nil), eventID: eventID)
        #expect(plan.primary == .markComplete(eventID: eventID))
        #expect(plan.secondary == .openEvent(eventID: eventID))
    }

    @Test func awaitingOutcomeOffersOnlyConfirmOutcomeEvenWithANextTask() {
        // Phase 10.1 (docs/25 "G."): Awaiting Outcome never offers a one-tap complete action,
        // regardless of whether a next task still exists — and no redundant Open Event
        // secondary, since Confirm Outcome already deep-links to the same destination.
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .awaitingOutcome, nextTaskID: UUID()), eventID: eventID)
        #expect(plan.primary == .confirmOutcome(eventID: eventID))
        #expect(plan.secondary == nil)
    }

    @Test func completedExposesNoMutationOnlyOpenEventNavigation() {
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .completed, nextTaskID: UUID()), eventID: eventID)
        #expect(plan.primary == nil)
        #expect(plan.secondary == .openEvent(eventID: eventID))
    }

    @Test func removedExposesNoMutationOnlyOpenEventNavigation() {
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .removed), eventID: eventID)
        #expect(plan.primary == nil)
        #expect(plan.secondary == .openEvent(eventID: eventID))
    }

    @Test(arguments: [
        KueLiveActivityAttributes.ContentState.Terminal.cancelled,
        .skipped,
        .unavailable
    ])
    func everyTerminalStateExposesNoMutationRegardlessOfPhase(terminal: KueLiveActivityAttributes.ContentState.Terminal) {
        let plan = LiveActivityActionPolicy.plan(for: state(phase: .countdown, nextTaskID: UUID(), terminal: terminal), eventID: eventID)
        #expect(plan.primary == nil)
        #expect(plan.secondary == .openEvent(eventID: eventID))
    }

    // MARK: - Never more than two actions, across every reachable state

    @Test(arguments: WidgetLifecyclePhase.allCases)
    func noStateEverExposesMoreThanTwoActions(phase: WidgetLifecyclePhase) {
        for terminal: KueLiveActivityAttributes.ContentState.Terminal? in [nil, .cancelled, .skipped, .unavailable] {
            let plan = LiveActivityActionPolicy.plan(
                for: state(phase: phase, nextTaskID: UUID(), canSnoozeNextTask: true, terminal: terminal),
                eventID: eventID
            )
            let count = [plan.primary, plan.secondary].compactMap { $0 }.count
            #expect(count <= 2)
        }
    }
}
