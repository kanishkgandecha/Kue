//
//  EventActionsReconciliationTests.swift
//  KueTests
//
//  Kue 3.0 Phase 8 correction pass — docs/36 "Reconciliation lifetime". Proves the
//  `...AwaitingReconciliation` twins added to `EventActions` (`cancel`/`complete`/`skip`/
//  `archive`/`delete`) are genuinely deterministic: by the time each call returns, Live
//  Activity and Spotlight reconciliation have actually run — no `Task`, no sleep, no polling.
//  Every assertion below checks fake call counts/state *immediately* after `await`, which is
//  only possible because the reconciliation is no longer an orphaned, unawaited `Task`
//  (see `EventActions.swift`'s own header for the full root-cause writeup and the three real,
//  pre-existing production call sites — `CancelEventIntent`/`CompleteEventIntent`/
//  `SkipEventIntent`, `NotificationActionHandler` — this was actually fixing, not just this
//  phase's own test harness).
//
//  `.eventActionsSyncOutboxSerialized` — every call below goes through `EventActions`, which
//  marks the real, process-global `SystemCloudSyncStateStore.shared` via `SyncOutbox
//  .markEventDirty` with no way to inject a fake (see `EventActionsSyncOutboxTestLock.swift`'s
//  own header) — the same cross-suite hazard `EventCRUDTests`/`EventActionsNotificationTests`
//  already guard against, so this new suite joins the same lock rather than risk racing them.
//

import Testing
import Foundation
import SwiftData
import UserNotifications
@testable import Kue

@Suite(.eventActionsSyncOutboxSerialized)
@MainActor
struct EventActionsReconciliationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEvent(context: ModelContext) -> KueEvent {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now.addingTimeInterval(3600), estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)
        try? context.save()
        return event
    }

    /// A Live Activity is "focused" on this event for the purposes of `LiveActivityReconciler
    /// .reconcile` — otherwise `reconcileFocusedActivity` (and its call-count) never fires
    /// regardless of whether reconciliation genuinely ran, making the assertion meaningless.
    private func makeFocusedManager(on event: KueEvent) async -> FakeLiveActivityManager {
        let manager = FakeLiveActivityManager()
        _ = await manager.start(for: event, now: now)
        return manager
    }

    // MARK: - Deterministic completion (no sleep, no polling)

    @Test func cancelAwaitingReconciliationFinishesBeforeReturning() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.cancelAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect(event.isCancelled)
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.indexCallCount == 1)
        #expect(indexer.indexedPayloads[event.id] != nil)
    }

    @Test func completeAwaitingReconciliationFinishesBeforeReturning() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.completeAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect(event.isManuallyCompleted)
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.indexCallCount == 1)
    }

    @Test func skipAwaitingReconciliationFinishesBeforeReturning() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        event.seriesID = UUID()
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.skipAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect(event.isSkipped)
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.indexCallCount == 1)
    }

    @Test func archiveAwaitingReconciliationFinishesBeforeReturning() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.archiveAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect(event.status == .archived)
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.indexCallCount == 1)
    }

    @Test func deleteAwaitingReconciliationFinishesBeforeReturning() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let eventID = event.id
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.deleteAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect((try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })))?.first == nil)
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.removeCallCount == 1)
    }

    // MARK: - Containers/contexts can be released safely right after awaited completion

    /// The exact shape that used to crash (`ModelContext.reset` on a destroyed instance) when
    /// reconciliation was an orphaned `Task`: build a container in a narrow scope, await the
    /// mutation, and let the container go out of scope immediately after — nothing should be
    /// left running against it.
    @Test func containerCanBeReleasedImmediatelyAfterAwaitedCompletion() async {
        func mutateInNarrowScope() async -> UUID {
            let context = ModelContext(ModelContainerFactory.makeInMemory())
            let event = makeEvent(context: context)
            await EventActions.cancelAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: FakeLiveActivityManager(), spotlightIndexer: FakeSpotlightIndexer())
            return event.id
            // `context`/its container go out of scope here — nothing should still be touching them.
        }
        _ = await mutateInNarrowScope()
        // Reaching this line without a fatal error/crash from an orphaned task IS the assertion.
        #expect(Bool(true))
    }

    // MARK: - Idempotency

    @Test func cancellingTwiceIsIdempotentAndDeterministic() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let manager = await makeFocusedManager(on: event)
        let indexer = FakeSpotlightIndexer()

        await EventActions.cancelAwaitingReconciliation(event, context: context, now: now, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)
        await EventActions.cancelAwaitingReconciliation(event, context: context, now: now.addingTimeInterval(60), scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer)

        #expect(event.isCancelled)
        // The first cancel ends the focused Live Activity (`.cancelled` is a terminal phase —
        // `FakeLiveActivityManager.reconcileFocusedActivity`'s own policy, mirroring
        // `SystemLiveActivityManager`), so `LiveActivityReconciler.reconcile`'s own
        // `focusedEventID() == nil` guard short-circuits the second call — the *real*,
        // correct idempotent behavior is "no redundant reconciliation work," not "identical
        // call counts every time." Spotlight indexing has no such early-exit and re-indexes
        // the (unchanged) terminal state harmlessly both times.
        #expect(manager.reconcileCallCount == 1)
        #expect(indexer.indexCallCount == 2)
    }

    @Test func completingTwiceIsIdempotent() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let scheduler = FakeNotificationScheduler()

        await EventActions.completeAwaitingReconciliation(event, context: context, now: now, scheduler: scheduler, liveActivityManager: FakeLiveActivityManager(), spotlightIndexer: FakeSpotlightIndexer())
        let firstCompletedAt = event.manuallyCompletedAt
        await EventActions.completeAwaitingReconciliation(event, context: context, now: now.addingTimeInterval(60), scheduler: scheduler, liveActivityManager: FakeLiveActivityManager(), spotlightIndexer: FakeSpotlightIndexer())

        #expect(event.isManuallyCompleted)
        #expect(event.manuallyCompletedAt != firstCompletedAt) // re-applies with the new `now`, deterministically — not "stuck"
    }

    // MARK: - Notification cleanup still happens (never bypassed by the awaitable path)

    @Test func cancelAwaitingReconciliationStillRemovesPendingNotifications() async {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = makeEvent(context: context)
        let scheduler = FakeNotificationScheduler()
        let identifier = "\(event.id)-\(NotificationTransitionKind.today.identifierSuffix)"
        await scheduler.add(UNNotificationRequest(identifier: identifier, content: UNNotificationContent(), trigger: nil))

        await EventActions.cancelAwaitingReconciliation(event, context: context, now: now, scheduler: scheduler, liveActivityManager: FakeLiveActivityManager(), spotlightIndexer: FakeSpotlightIndexer())

        #expect(!scheduler.addedIdentifiers.contains(identifier))
    }
}
