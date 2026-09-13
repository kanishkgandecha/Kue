//
//  PlanningActionRouterTests.swift
//  KueTests
//
//  Kue 3.0 Phase 8 — docs/36 "F." Confirms every accept/confirm-outcome/focus-block action
//  routes through the *existing* mutation services — `TaskEditingService`, `EventActions`,
//  `CalendarProviding` — never a second, parallel mutation path, using the exact fakes
//  (`FakeNotificationScheduler`, `FakeCalendarProvider`) every other mutation-service test
//  file already uses.
//
//  Kue 3.0 Phase 8 correction pass — docs/36 "Reconciliation lifetime". An earlier version of
//  this file worked around a real crash (`ModelContext.reset` on a destroyed instance, caused
//  by `EventActions.complete`/`.cancel` firing *unawaited* reconciliation `Task`s that could
//  still be running against a short-lived per-test container once the next test began) with a
//  timing-based `settle()` sleep. That was treating the symptom. The actual root cause — and a
//  real, pre-existing production hazard, not just a test artifact — is fixed at the source in
//  `EventActions.swift` (see that file's own header): `PlanningActionRouter.confirmOutcome` now
//  calls the new `...AwaitingReconciliation` variants, which genuinely await Live Activity and
//  Spotlight reconciliation before returning. No sleep, no polling, no arbitrary delay anywhere
//  in this file any more — every test below either awaits a real completion signal or performs
//  no async mutation with an orphaned continuation at all.
//
//  `PlanningSnapshotBuilder`'s own tests live in this same file/suite (rather than a separate
//  file) purely for historical reasons (they were folded in while diagnosing the crash above);
//  `.serialized` is kept out of caution for the several `ModelContainerFactory.makeInMemory()`
//  containers this file still creates directly (matching
//  `KueMacTests/MacModelContainerFactoryTests.swift`'s own documented precedent for that class
//  of SwiftData concurrency risk) — no longer strictly required for the reconciliation-lifetime
//  hazard itself (that's now structurally impossible: the awaited path never spawns a `Task`),
//  but cheap insurance against the general "many in-memory containers churn quickly" risk.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite(.serialized)
@MainActor
struct PlanningActionRouterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEventAndTask(context: ModelContext) -> (KueEvent, KueTask) {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now.addingTimeInterval(3 * 86_400), estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)
        let task = KueTask(event: event, title: "Prep", dueDate: now.addingTimeInterval(2 * 86_400), offsetLabel: "1 day before")
        context.insert(task)
        event.tasks.append(task)
        try? context.save()
        return (event, task)
    }

    // MARK: - Accept (move-earlier-style recommendation with a proposedDate)

    @Test func acceptingADateChangeRecommendationReschedulesTheRealTaskThroughTaskEditingService() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let (_, task) = makeEventAndTask(context: context)
        let newDate = now.addingTimeInterval(86_400)

        let recommendation = PlanningRecommendation(
            id: "moveEarlier-test", category: .moveTaskEarlier, title: "Move earlier",
            explanation: "test", contributingFactors: [], confidence: .medium, suggestedAction: .accept,
            availableActions: [.accept], affectedTaskIDs: [task.id], createdAt: now, expiresAt: now, proposedDate: newDate
        )

        try await PlanningActionRouter.accept(recommendation, context: context, scheduler: FakeNotificationScheduler(), now: now)

        #expect(task.dueDate == newDate)
        #expect(RecommendationDismissalStore.isSuppressed(id: recommendation.id, now: now))
        RecommendationDismissalStore.resetAll()
    }

    @Test func acceptingAFocusBlockOnlyRecommendationMutatesNothingButRecordsTheDismissal() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let (_, task) = makeEventAndTask(context: context)
        let originalDate = task.dueDate

        let recommendation = PlanningRecommendation(
            id: "schedulePrep-test", category: .schedulePreparation, title: "Schedule",
            explanation: "test", contributingFactors: [], confidence: .medium, suggestedAction: .accept,
            availableActions: [.accept], affectedTaskIDs: [task.id], createdAt: now, expiresAt: now
        )

        try await PlanningActionRouter.accept(recommendation, context: context, scheduler: FakeNotificationScheduler(), now: now)

        #expect(task.dueDate == originalDate) // unchanged — no model to persist a focus block into
        #expect(RecommendationDismissalStore.isSuppressed(id: recommendation.id, now: now))
        RecommendationDismissalStore.resetAll()
    }

    // MARK: - Confirm Outcome (routes through EventActions — never a parallel completion path)

    @Test func confirmOutcomeAsCompleteCallsEventActionsComplete() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let (event, _) = makeEventAndTask(context: context)
        let manager = FakeLiveActivityManager()
        let indexer = FakeSpotlightIndexer()

        let recommendation = PlanningRecommendation(
            id: "confirmOutcome-test", category: .confirmEventOutcome, title: "Confirm",
            explanation: "test", contributingFactors: [], confidence: .high, suggestedAction: .confirmOutcome,
            availableActions: [.confirmOutcome], affectedEventIDs: [event.id], createdAt: now, expiresAt: now
        )

        try await PlanningActionRouter.confirmOutcome(recommendation, as: .complete, context: context, scheduler: FakeNotificationScheduler(), liveActivityManager: manager, spotlightIndexer: indexer, now: now)

        // Reconciliation genuinely finished by the time `confirmOutcome` returned — no sleep
        // needed to make this assertion safe.
        #expect(event.isManuallyCompleted)
        #expect(event.isCancelled == false)
        #expect(indexer.indexCallCount == 1)
    }

    @Test func confirmOutcomeAsCancelCallsEventActionsCancel() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let (event, _) = makeEventAndTask(context: context)
        let indexer = FakeSpotlightIndexer()

        let recommendation = PlanningRecommendation(
            id: "confirmOutcome-test-2", category: .confirmEventOutcome, title: "Confirm",
            explanation: "test", contributingFactors: [], confidence: .high, suggestedAction: .confirmOutcome,
            availableActions: [.confirmOutcome], affectedEventIDs: [event.id], createdAt: now, expiresAt: now
        )

        try await PlanningActionRouter.confirmOutcome(recommendation, as: .cancel, context: context, scheduler: FakeNotificationScheduler(), spotlightIndexer: indexer, now: now)

        #expect(event.isCancelled)
        #expect(indexer.indexCallCount == 1)
    }

    // MARK: - Focus block: Add to Calendar (existing CalendarProviding abstraction)

    @Test func addFocusBlockToCalendarSavesThroughTheCalendarProvider() throws {
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [KueWritableCalendar(calendarIdentifier: "cal-1", title: "Home", sourceTitle: "Fake")])
        let block = FocusBlockProposal(id: "focus-1", start: now, durationMinutes: 30, title: "Deep work", taskID: nil, eventID: nil)

        try PlanningActionRouter.addFocusBlockToCalendar(block, calendarProvider: provider, calendarIdentifier: "cal-1")

        #expect(provider.saveCallCount == 1)
    }

    @Test func addFocusBlockToCalendarThrowsHonestlyWhenCalendarIsUnavailable() {
        let provider = FakeCalendarProvider(stateToReturn: .denied)
        let block = FocusBlockProposal(id: "focus-2", start: now, durationMinutes: 30, title: "Deep work", taskID: nil, eventID: nil)

        #expect(throws: PlanningActionRouter.RoutingError.self) {
            try PlanningActionRouter.addFocusBlockToCalendar(block, calendarProvider: provider, calendarIdentifier: "cal-1")
        }
        #expect(provider.saveCallCount == 0)
    }

    // MARK: - Dismiss / snooze (never touch a model)

    @Test func dismissAndSnoozeNeverMutateTheModelGraph() throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let (event, task) = makeEventAndTask(context: context)
        let originalTitle = event.title
        let originalDueDate = task.dueDate

        let recommendation = PlanningRecommendation(
            id: "dismiss-test", category: .reviewOverdueTask, title: "x", explanation: "x",
            contributingFactors: [], confidence: .medium, suggestedAction: .dismiss,
            availableActions: [.dismiss, .snooze], affectedEventIDs: [event.id], affectedTaskIDs: [task.id],
            createdAt: now, expiresAt: now
        )

        PlanningActionRouter.dismiss(recommendation, now: now)
        #expect(event.title == originalTitle)
        #expect(task.dueDate == originalDueDate)
        #expect(RecommendationDismissalStore.isSuppressed(id: recommendation.id, now: now))

        RecommendationDismissalStore.resetAll()
        PlanningActionRouter.snooze(recommendation, until: now.addingTimeInterval(3600), now: now)
        #expect(RecommendationDismissalStore.isSuppressed(id: recommendation.id, now: now.addingTimeInterval(1800)))
        RecommendationDismissalStore.resetAll()
    }

    // MARK: - PlanningSnapshotBuilder (folded in here — see file header for why)

    private func makeSnapshotFixtureEvent(context: ModelContext, status: EventStatus = .upcoming, startDate: Date? = nil) -> KueEvent {
        let event = KueEvent(
            title: "Event", eventType: .generic, startDate: startDate ?? now.addingTimeInterval(86_400),
            estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual, status: status
        )
        context.insert(event)
        try? context.save()
        return event
    }

    @Test func archivedEventsAreExcludedFromTheSnapshot() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let archived = makeSnapshotFixtureEvent(context: context, status: .archived, startDate: now.addingTimeInterval(-1_000_000))
        archived.isCancelled = true
        try? context.save()

        let (events, _) = PlanningSnapshotBuilder.snapshot(events: [archived], now: now)
        #expect(events.isEmpty)
    }

    @Test func statusIsDerivedViaEventStatusEngineNeverReimplemented() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        // Past its end date, no explicit outcome — must derive to `.awaitingOutcome`, the
        // exact same value `EventStatusEngine.derive` would produce, proving the snapshot
        // builder defers to it rather than reading the (possibly stale) persisted `status`.
        let event = makeSnapshotFixtureEvent(context: context, status: .upcoming, startDate: now.addingTimeInterval(-7200))

        let (events, _) = PlanningSnapshotBuilder.snapshot(events: [event], now: now)
        #expect(events.first?.status == .awaitingOutcome)
    }

    @Test func tasksAreCopiedFaithfullyWithTheirOwningEventID() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeSnapshotFixtureEvent(context: context)
        let task = KueTask(event: event, title: "Prep", dueDate: now, offsetLabel: "1 day before")
        context.insert(task)
        event.tasks.append(task)
        try? context.save()

        let (events, tasks) = PlanningSnapshotBuilder.snapshot(events: [event], now: now)
        #expect(events.first?.taskIDs == [task.id])
        #expect(tasks.first?.eventID == event.id)
        #expect(tasks.first?.title == "Prep")
    }
}
