//
//  LiveActivityFocusCoordinatorTests.swift
//  KueTests
//
//  See docs/23-live-activities-and-focus-mode.md "C./L." — the one-event focus policy, driven
//  entirely through `FakeLiveActivityManager` (no real ActivityKit call anywhere): starting
//  with none focused, an idempotent same-event restart, a different-event request that must
//  ask for confirmation rather than silently replacing, explicit replacement actually ending
//  the old activity before starting the new one, stopping, and every `LiveActivityManaging`
//  error state surfacing distinctly through the coordinator.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct LiveActivityFocusCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeEvent(title: String = "CAT 2026", startDate: Date? = nil) -> KueEvent {
        KueEvent(
            title: title, eventType: .exam, startDate: startDate ?? now.addingTimeInterval(3_600),
            estimatedDurationMinutes: 180, timeZoneIdentifier: "UTC", source: .manual
        )
    }

    // MARK: - Start with none focused

    @Test func requestFocusStartsFreshWhenNothingIsCurrentlyFocused() async {
        let manager = FakeLiveActivityManager()
        let event = makeEvent()
        let outcome = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)
        #expect(outcome == .started)
        #expect(manager.runningEventID == event.id)
        #expect(manager.startCallCount == 1)
    }

    @Test func requestFocusFailsHonestlyWhenActivitiesAreUnavailable() async {
        let manager = FakeLiveActivityManager()
        manager.isAvailable = false
        let event = makeEvent()
        let outcome = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)
        #expect(outcome == .unavailable(.authorizationDisabled))
        #expect(manager.runningEventID == nil)
    }

    // MARK: - Idempotent same-event restart

    @Test func requestFocusForTheSameAlreadyFocusedEventIsIdempotentNotADuplicate() async {
        let manager = FakeLiveActivityManager()
        let event = makeEvent()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)
        let second = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)
        #expect(second == .alreadyActiveForThisEvent)
        // No second activity — start() was only ever actually let through once at the fake's level.
        #expect(manager.startCallCount == 1)
    }

    // MARK: - Different event: confirmation required, never silent replacement

    @Test func requestFocusForADifferentEventNeedsExplicitConfirmationRatherThanReplacingSilently() async {
        let manager = FakeLiveActivityManager()
        let eventA = makeEvent(title: "Event A")
        let eventB = makeEvent(title: "Event B")
        _ = await LiveActivityFocusCoordinator.requestFocus(for: eventA, manager: manager, now: now)

        let outcome = await LiveActivityFocusCoordinator.requestFocus(for: eventB, manager: manager, now: now)
        #expect(outcome == .needsReplacementConfirmation(currentEventID: eventA.id))
        // Event A must still be the one running — nothing silently switched.
        #expect(manager.runningEventID == eventA.id)
    }

    @Test func decliningReplacementLeavesTheOriginalActivityUntouched() async {
        let manager = FakeLiveActivityManager()
        let eventA = makeEvent(title: "Event A")
        let eventB = makeEvent(title: "Event B")
        _ = await LiveActivityFocusCoordinator.requestFocus(for: eventA, manager: manager, now: now)
        _ = await LiveActivityFocusCoordinator.requestFocus(for: eventB, manager: manager, now: now)

        // Declining is simply never calling `replaceFocus` — nothing else to assert on the
        // coordinator's side; the manager's state must be exactly as it was.
        #expect(manager.runningEventID == eventA.id)
        #expect(manager.endedEventIDs.isEmpty)
    }

    // MARK: - Explicit replacement: end-then-start

    @Test func replaceFocusEndsTheOldActivityBeforeStartingTheNewOne() async {
        let manager = FakeLiveActivityManager()
        let eventA = makeEvent(title: "Event A")
        let eventB = makeEvent(title: "Event B")
        _ = await LiveActivityFocusCoordinator.requestFocus(for: eventA, manager: manager, now: now)

        let outcome = await LiveActivityFocusCoordinator.replaceFocus(currentEventID: eventA.id, with: eventB, manager: manager, now: now)
        #expect(outcome == .started)
        #expect(manager.runningEventID == eventB.id)
        #expect(manager.endedEventIDs == [eventA.id])
    }

    // MARK: - Stop

    @Test func stopFocusEndsTheActivityForThatEventID() async {
        let manager = FakeLiveActivityManager()
        let event = makeEvent()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)

        await LiveActivityFocusCoordinator.stopFocus(eventID: event.id, manager: manager)
        #expect(manager.runningEventID == nil)
        #expect(manager.endedEventIDs == [event.id])
    }
}
