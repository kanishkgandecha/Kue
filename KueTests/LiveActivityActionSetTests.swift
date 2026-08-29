//
//  LiveActivityActionSetTests.swift
//  KueTests
//
//  Post-Phase-12 fix — Live Activity visual redesign (docs/23 "K."). `actionSet(for:)`
//  (Shared/Services/LiveActivity/LiveActivityActionSet.swift) is the one place both the Lock
//  Screen and Dynamic Island Expanded Bottom views decide which action row to show — these
//  tests are the "state chooses correct action set" / "terminal states expose no active
//  actions" coverage the visual-polish task asked for.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct LiveActivityActionSetTests {
    private func state(
        phase: WidgetLifecyclePhase,
        nextTaskID: UUID? = nil,
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
            canSnoozeNextTask: false,
            terminal: terminal,
            lastUpdated: .now
        )
    }

    @Test func genuinelyTrackingWithANextTaskOffersCompleteTaskAndMarkComplete() {
        #expect(actionSet(for: state(phase: .preparation, nextTaskID: UUID())) == .activeWithNextTask)
    }

    @Test func genuinelyTrackingWithNoNextTaskOffersOnlyMarkComplete() {
        #expect(actionSet(for: state(phase: .countdown, nextTaskID: nil)) == .activeNoNextTask)
    }

    @Test func awaitingOutcomeOffersOnlyConfirmOutcomeEvenWithANextTask() {
        // Phase 10.1 (docs/25 "G."): Awaiting Outcome never offers a one-tap complete action,
        // regardless of whether a next task still exists.
        #expect(actionSet(for: state(phase: .awaitingOutcome, nextTaskID: UUID())) == .awaitingOutcome)
    }

    @Test func completedExposesNoActiveActions() {
        #expect(actionSet(for: state(phase: .completed, nextTaskID: UUID())) == .none)
    }

    @Test func removedExposesNoActiveActions() {
        #expect(actionSet(for: state(phase: .removed)) == .none)
    }

    @Test(arguments: [
        KueLiveActivityAttributes.ContentState.Terminal.cancelled,
        .skipped,
        .unavailable
    ])
    func everyTerminalStateExposesNoActiveActionsRegardlessOfPhase(terminal: KueLiveActivityAttributes.ContentState.Terminal) {
        #expect(actionSet(for: state(phase: .countdown, nextTaskID: UUID(), terminal: terminal)) == .none)
    }
}
