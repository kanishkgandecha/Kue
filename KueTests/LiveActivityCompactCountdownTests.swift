//
//  LiveActivityCompactCountdownTests.swift
//  KueTests
//
//  Kue 3.0 Phase 2 (docs/30) — `LiveActivityCompactCountdown.label(for:now:)` is the one place
//  Dynamic Island's Compact Trailing and every Lock Screen tier get a short countdown/state
//  word from. Covers days/hours/"Now"/large-value formatting, every terminal case, and every
//  non-countdown phase — the "Countdown formatting for days, hours, now, and large values" /
//  "compact labels remain within documented character budgets" coverage docs/30's spec calls
//  for directly.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct LiveActivityCompactCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func state(
        phase: WidgetLifecyclePhase,
        effectiveStartDate: Date,
        effectiveEndDate: Date? = nil,
        terminal: KueLiveActivityAttributes.ContentState.Terminal? = nil
    ) -> KueLiveActivityAttributes.ContentState {
        KueLiveActivityAttributes.ContentState(
            displayTitle: "Fixture Event",
            eventTypeDisplayName: "Event",
            phase: phase,
            isUrgent: false,
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate ?? effectiveStartDate.addingTimeInterval(3600),
            countdownSubline: nil,
            tasksCompleted: 0,
            tasksTotal: 0,
            nextTaskID: nil,
            nextTaskSummary: nil,
            remainingTaskCount: 0,
            canSnoozeNextTask: false,
            terminal: terminal,
            lastUpdated: now
        )
    }

    // MARK: - Days / hours / minutes / large values

    @Test func daysAwayFormatsAsWholeDays() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .countdown, effectiveStartDate: now.addingTimeInterval(19 * 86_400)), now: now)
        #expect(label == "19d")
    }

    @Test func threeDigitDaysStillFormatsReadably() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .countdown, effectiveStartDate: now.addingTimeInterval(128 * 86_400)), now: now)
        #expect(label == "128d")
    }

    @Test func hoursAwayFormatsAsWholeHoursOnceUnderADay() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .today, effectiveStartDate: now.addingTimeInterval(3 * 3600)), now: now)
        #expect(label == "3h")
    }

    @Test func minutesAwayFormatsAsWholeMinutesOnceUnderAnHour() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .today, effectiveStartDate: now.addingTimeInterval(15 * 60)), now: now)
        #expect(label == "15m")
    }

    @Test func startingImmediatelyFormatsAsNow() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .today, effectiveStartDate: now), now: now)
        #expect(label == "Now")
    }

    @Test func genuinelyInProgressFormatsAsNow() {
        let label = LiveActivityCompactCountdown.label(
            for: state(phase: .today, effectiveStartDate: now.addingTimeInterval(-1800), effectiveEndDate: now.addingTimeInterval(1800)),
            now: now
        )
        #expect(label == "Now")
    }

    // MARK: - Non-countdown phases

    @Test func awaitingOutcomeFormatsAsReview() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .awaitingOutcome, effectiveStartDate: now.addingTimeInterval(-3600)), now: now)
        #expect(label == "Review")
    }

    @Test func completedFormatsAsDone() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .completed, effectiveStartDate: now.addingTimeInterval(-86_400)), now: now)
        #expect(label == "Done")
    }

    @Test func removedFormatsAsArchived() {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .removed, effectiveStartDate: now.addingTimeInterval(-10 * 86_400)), now: now)
        #expect(label == "Archived")
    }

    // MARK: - Terminal states always win, regardless of phase or timing

    @Test(arguments: [
        (KueLiveActivityAttributes.ContentState.Terminal.cancelled, "Cancelled"),
        (.skipped, "Skipped"),
        (.unavailable, "Gone")
    ])
    func terminalStatesFormatToTheirOwnShortWordRegardlessOfPhase(terminal: KueLiveActivityAttributes.ContentState.Terminal, expected: String) {
        let label = LiveActivityCompactCountdown.label(for: state(phase: .countdown, effectiveStartDate: now.addingTimeInterval(5 * 86_400), terminal: terminal), now: now)
        #expect(label == expected)
    }

    // MARK: - Character budget — every branch stays short enough for Compact Trailing/Minimal

    @Test func everyBranchStaysWithinAShortCharacterBudget() {
        let fixtures: [KueLiveActivityAttributes.ContentState] = [
            state(phase: .countdown, effectiveStartDate: now.addingTimeInterval(999 * 86_400)),
            state(phase: .today, effectiveStartDate: now.addingTimeInterval(3 * 3600)),
            state(phase: .today, effectiveStartDate: now),
            state(phase: .awaitingOutcome, effectiveStartDate: now.addingTimeInterval(-3600)),
            state(phase: .completed, effectiveStartDate: now.addingTimeInterval(-86_400)),
            state(phase: .removed, effectiveStartDate: now.addingTimeInterval(-86_400)),
            state(phase: .countdown, effectiveStartDate: now.addingTimeInterval(86_400), terminal: .cancelled),
        ]
        for fixture in fixtures {
            // "Cancelled" (9 characters) is the longest branch this formatter ever returns —
            // every numeric/"Now"/"Review"/"Done"/"Archived"/"Gone" branch is shorter still.
            #expect(LiveActivityCompactCountdown.label(for: fixture, now: now).count <= 9)
        }
    }
}
