//
//  LiveActivityReconcilerTests.swift
//  KueTests
//
//  See docs/23-live-activities-and-focus-mode.md "G./L." — the one bounded reconciliation
//  pass: no-op when nothing is focused, ends the activity when its event has been deleted
//  (never falls back to Next Up), ends it after a terminal mutation (completed/archived/
//  cancelled/skipped), and just updates it while the event is still genuinely tracking. Also
//  covers `LiveActivityReconciler.reconcile` never touching a *different* event's activity —
//  the coordinator's/manager's own "only ever the one it was started with" invariant.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct LiveActivityReconcilerTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func makeEvent(startDate: Date, estimatedDurationMinutes: Int = 180) -> KueEvent {
        KueEvent(
            title: "CAT 2026", eventType: .exam, startDate: startDate,
            estimatedDurationMinutes: estimatedDurationMinutes, timeZoneIdentifier: "UTC", source: .manual
        )
    }

    @Test func reconcileIsANoOpWhenNothingIsFocused() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let didReconcile = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        #expect(didReconcile == false)
        #expect(manager.reconcileCallCount == 0)
    }

    @Test func reconcileEndsTheActivityWhenItsEventHasBeenDeletedNeverFallingBackToNextUp() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        context.insert(event)
        try? context.save()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)

        let otherEvent = makeEvent(startDate: now.addingTimeInterval(60)) // more urgent — must never be picked up
        context.insert(otherEvent)
        context.delete(event)
        try? context.save()

        let didReconcile = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        #expect(didReconcile)
        #expect(manager.runningEventID == nil)
        #expect(manager.endedEventIDs == [event.id])
    }

    @Test func reconcileEndsTheActivityAfterTheEventIsManuallyCompleted() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let event = makeEvent(startDate: now.addingTimeInterval(-3_600), estimatedDurationMinutes: 0)
        context.insert(event)
        try? context.save()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)

        EventActions.complete(event, context: context, now: now, liveActivityManager: manager)

        // `complete` reconciles fire-and-forget (app-process path) — reconcile directly too,
        // matching what the awaited widget-extension path would already guarantee.
        _ = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        #expect(manager.runningEventID == nil)
    }

    @Test func reconcileEndsTheActivityAfterTheEventIsCancelled() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        context.insert(event)
        try? context.save()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)

        event.isCancelled = true
        event.cancelledAt = now
        try? context.save()

        _ = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        #expect(manager.runningEventID == nil)
        #expect(manager.endedEventIDs == [event.id])
    }

    @Test func reconcileJustUpdatesWhileTheEventIsStillGenuinelyTracking() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let event = makeEvent(startDate: now.addingTimeInterval(3_600))
        context.insert(event)
        try? context.save()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager, now: now)

        event.title = "CAT 2026 (Rescheduled)"
        try? context.save()

        _ = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        #expect(manager.runningEventID == event.id) // still running — never ended
        #expect(manager.lastContentState?.displayTitle == "CAT 2026 (Rescheduled)")
    }

    @Test func reconcileNeverTouchesADifferentEventThanTheOneFocused() async {
        let manager = FakeLiveActivityManager()
        let context = makeContext()
        let focused = makeEvent(startDate: now.addingTimeInterval(3_600))
        let unrelated = makeEvent(startDate: now.addingTimeInterval(60))
        context.insert(focused)
        context.insert(unrelated)
        try? context.save()
        _ = await LiveActivityFocusCoordinator.requestFocus(for: focused, manager: manager, now: now)

        unrelated.isCancelled = true
        try? context.save()

        _ = await LiveActivityReconciler.reconcile(context: context, manager: manager, now: now)
        // Only the focused event was ever fetched/passed to the manager — unrelated's own
        // cancellation has no bearing on it.
        #expect(manager.runningEventID == focused.id)
        #expect(manager.endedEventIDs.isEmpty)
    }
}
