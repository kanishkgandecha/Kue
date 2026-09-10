//
//  LiveActivityStateBuilderTests.swift
//  KueTests
//
//  See docs/23-live-activities-and-focus-mode.md "L." — pure state-building coverage:
//  per-phase/terminal-state content, timed vs. all-day, pinned timezone/DST, preparation
//  progress/next task, privacy redaction, the always-`.unavailable` deleted-event path, and
//  deterministic/Codable-round-trip output. No ActivityKit involved — this is exactly the same
//  `DedicatedWidgetContentService.resolve` input `DedicatedWidgetContentServiceTests.swift`
//  already covers exhaustively, so these tests focus on what `LiveActivityStateBuilder` adds
//  on top: privacy, terminal mapping, and the `ContentState` shape itself.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct LiveActivityStateBuilderTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // fixed, arbitrary reference instant

    private func makeEvent(
        title: String = "CAT 2026",
        eventType: EventType = .exam,
        startDate: Date,
        estimatedDurationMinutes: Int = 180,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = "UTC",
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false
    ) -> KueEvent {
        let event = KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: estimatedDurationMinutes,
            isAllDay: isAllDay, timeZoneIdentifier: timeZoneIdentifier, source: .manual,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, isSkipped: isSkipped
        )
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown)
        return event
    }

    // MARK: - Attributes (identity, pinned at request time)

    @Test func attributesPinEventIdentityAndTimezone() {
        let event = makeEvent(startDate: now.addingTimeInterval(93 * 86_400), timeZoneIdentifier: "America/New_York")
        let attributes = LiveActivityStateBuilder.attributes(for: event)
        #expect(attributes.eventID == event.id)
        #expect(attributes.eventType == .exam)
        #expect(attributes.timeZoneIdentifier == "America/New_York")
        #expect(attributes.isAllDay == false)
    }

    // MARK: - Tracking state (phase, urgency, prep progress, next task)

    @Test func trackingStateCarriesPreparationProgressAndNextTask() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 86_400))
        let task1 = KueTask(event: event, title: "Review notes", dueDate: now.addingTimeInterval(3_600), isCompleted: true, offsetLabel: "2 days before")
        let task2 = KueTask(event: event, title: "Pack materials", dueDate: now.addingTimeInterval(7_200), offsetLabel: "1 day before")
        event.tasks = [task1, task2]

        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(state.tasksCompleted == 1)
        #expect(state.tasksTotal == 2)
        #expect(state.remainingTaskCount == 1)
        #expect(state.nextTaskID == task2.id)
        #expect(state.terminal == nil)
    }

    // Kue 3.0 Phase 2 (docs/30) fix — these two fields previously always carried `now` (dead
    // placeholder data), leaving `LiveActivityCompactCountdown` nothing real to format an
    // "3h"/"Now" countdown from. Confirms they now carry the event's own real window.
    @Test func trackingStateCarriesTheEventsRealStartAndEffectiveEndDateNotNow() {
        let start = now.addingTimeInterval(2 * 86_400)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 180)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(state.effectiveStartDate == start)
        #expect(state.effectiveEndDate == event.effectiveEndDate)
        #expect(state.effectiveStartDate != now)
    }

    @Test func allDayEventUsesCalendarDaySemanticsSameAsTheDedicatedWidget() {
        let event = makeEvent(startDate: now, isAllDay: true, timeZoneIdentifier: "UTC")
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        // Mirrors DedicatedWidgetContentServiceTests' own all-day coverage — the builder must
        // not re-derive lifecycle rules, only forward whatever the resolver already decided.
        #expect(state.phase == WidgetContentService.currentPhase(for: event, now: now))
    }

    @Test func pinnedTimezoneDrivesTheResultNotTheCurrentDeviceTimezone() {
        // A DST-adjacent instant in America/New_York, pinned regardless of test-host timezone.
        let dstBoundary = Date(timeIntervalSince1970: 1_699_167_600) // 2023-11-05 06:00 UTC — US fall-back day
        let event = makeEvent(startDate: dstBoundary, timeZoneIdentifier: "America/New_York")
        let stateAtNY = LiveActivityStateBuilder.contentState(for: event, now: dstBoundary.addingTimeInterval(-3_600))
        // Deterministic — same inputs, same output, regardless of when the test itself runs.
        let stateAtNYAgain = LiveActivityStateBuilder.contentState(for: event, now: dstBoundary.addingTimeInterval(-3_600))
        #expect(stateAtNY == stateAtNYAgain)
    }

    // MARK: - Privacy redaction (docs/23 "I.")

    @Test func titleIsRedactedToAGenericLabelWhenShowTitleIsOff() {
        let event = makeEvent(title: "Sensitive Deposition Prep", startDate: now.addingTimeInterval(3_600))
        let privacy = LiveActivityPrivacyPreference(showTitle: false, showNextTask: false)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now, privacy: privacy)
        #expect(state.displayTitle == EventType.exam.displayName)
        #expect(state.displayTitle != "Sensitive Deposition Prep")
    }

    @Test func nextTaskTitleIsHiddenByDefaultButIDStaysAvailableForTheCompleteButton() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        let task = KueTask(event: event, title: "Call the lawyer", dueDate: now.addingTimeInterval(1_800), offsetLabel: "soon")
        event.tasks = [task]

        let state = LiveActivityStateBuilder.contentState(for: event, now: now, privacy: .conservativeDefault)
        #expect(LiveActivityPrivacyPreference.conservativeDefault.showNextTask == false)
        #expect(state.nextTaskSummary == nil)
        // The interactive "Complete Task" button still needs a real id even when the title is hidden.
        #expect(state.nextTaskID == task.id)
    }

    @Test func nextTaskTitleAppearsOnceShowNextTaskIsOn() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        let task = KueTask(event: event, title: "Call the lawyer", dueDate: now.addingTimeInterval(1_800), offsetLabel: "soon")
        event.tasks = [task]

        let privacy = LiveActivityPrivacyPreference(showTitle: true, showNextTask: true)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now, privacy: privacy)
        #expect(state.nextTaskSummary == "Call the lawyer")
    }

    // MARK: - Terminal states

    @Test func cancelledProducesAnExplicitTerminalStateNotAFallback() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600), isCancelled: true)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(state.terminal == .cancelled)
    }

    @Test func skippedProducesAnExplicitTerminalStateNotAFallback() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600), isSkipped: true)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(state.terminal == .skipped)
    }

    @Test func completedIsATrackingPhaseNotATerminalCase() {
        // Completed/removed are ordinary `.phase` values the reconciler ends the activity for
        // (grace period), not a distinct `Terminal` case — mirrors `DedicatedWidgetResolution`.
        let event = makeEvent(startDate: now.addingTimeInterval(-3_600), estimatedDurationMinutes: 0, isManuallyCompleted: true)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(state.terminal == nil)
        #expect(state.phase == .completed)
    }

    // MARK: - Deleted event (no KueEvent left to read at all)

    @Test func unavailableContentStateIsAlwaysUnavailableNeverCancelledOrSkipped() {
        let state = LiveActivityStateBuilder.unavailableContentState(eventType: .interview, now: now)
        #expect(state.terminal == .unavailable)
        #expect(state.displayTitle == EventType.interview.displayName)
        #expect(state.nextTaskID == nil)
        #expect(state.tasksTotal == 0)
    }

    // MARK: - Codable round-trip (ActivityKit persists ContentState across process boundaries)

    @Test func contentStateSurvivesACodableRoundTrip() throws {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        let task = KueTask(event: event, title: "Prep", dueDate: now.addingTimeInterval(1_800), offsetLabel: "soon")
        event.tasks = [task]
        let original = LiveActivityStateBuilder.contentState(for: event, now: now, privacy: .init(showTitle: true, showNextTask: true))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KueLiveActivityAttributes.ContentState.self, from: data)
        #expect(decoded == original)
    }

    @Test func attributesSurviveACodableRoundTrip() throws {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600), timeZoneIdentifier: "Europe/London")
        let original = LiveActivityStateBuilder.attributes(for: event)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KueLiveActivityAttributes.self, from: data)
        #expect(decoded.eventID == original.eventID)
        #expect(decoded.timeZoneIdentifier == original.timeZoneIdentifier)
    }

    // MARK: - Determinism

    @Test func sameInputsProduceIdenticalOutputRegardlessOfCallOrder() {
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        let first = LiveActivityStateBuilder.contentState(for: event, now: now)
        let second = LiveActivityStateBuilder.contentState(for: event, now: now)
        #expect(first == second)
    }
}
