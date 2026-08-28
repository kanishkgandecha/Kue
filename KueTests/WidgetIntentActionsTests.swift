//
//  WidgetIntentActionsTests.swift
//  KueTests
//
//  See docs/07-widget-engine.md "Interactive widgets — Phase 9 (inside V1, not post-V1)".
//  Requirement: persistence, bounds, unavailable snooze, missing records, notification
//  cleanup, timeline reload invocation through an injectable wrapper, and task/event status
//  separation — all through `WidgetIntentActions` directly (the same functions
//  CompleteTaskIntent/SnoozeTaskIntent/CompleteEventIntent call), with fakes standing in for
//  `UNUserNotificationCenter`/`WidgetCenter`. No real widget-extension process involved.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct WidgetIntentActionsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func insertEvent(
        in context: ModelContext,
        startDate: Date,
        eventType: EventType = .interview
    ) -> KueEvent {
        let event = KueEvent(
            title: "Interview",
            eventType: eventType,
            startDate: startDate,
            estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        context.insert(event)
        try? context.save()
        return event
    }

    private func insertTask(_ event: KueEvent, in context: ModelContext, dueDate: Date, offsetLabel: String = "1 day before") -> KueTask {
        let task = KueTask(event: event, title: "Review", dueDate: dueDate, offsetLabel: offsetLabel)
        context.insert(task)
        event.tasks.append(task)
        try? context.save()
        return task
    }

    // MARK: - CompleteTaskIntent

    @Test func completeTaskPersistsCompletionFields() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(5 * 86_400))

        let scheduler = FakeNotificationScheduler()
        let reloader = FakeWidgetReloader()
        _ = try WidgetIntentActions.completeTask(taskID: task.id, context: context, scheduler: scheduler, widgetReloader: reloader, now: now)

        #expect(task.isCompleted)
        #expect(task.completedAt == now)
    }

    @Test func completeTaskRemovesOnlyThatTasksNotificationIdentifier() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(5 * 86_400))
        let otherTask = insertTask(event, in: context, dueDate: now.addingTimeInterval(6 * 86_400))

        let scheduler = FakeNotificationScheduler()
        let reloader = FakeWidgetReloader()
        _ = try WidgetIntentActions.completeTask(taskID: task.id, context: context, scheduler: scheduler, widgetReloader: reloader, now: now)

        let expectedIdentifier = "\(event.id)-task-\(task.id.uuidString)"
        let otherIdentifier = "\(event.id)-task-\(otherTask.id.uuidString)"
        #expect(scheduler.allRemovedIdentifiers.contains(expectedIdentifier))
        #expect(!scheduler.allRemovedIdentifiers.contains(otherIdentifier))
        #expect(!scheduler.allRemovedIdentifiers.contains("\(event.id)-tomorrow"))
    }

    @Test func completeTaskInvokesTheInjectableWidgetReloader() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(5 * 86_400))

        let reloader = FakeWidgetReloader()
        _ = try WidgetIntentActions.completeTask(taskID: task.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: reloader, now: now)

        // Kue 2.0 Phase 8 — a mutation from either widget kind's own button can affect a
        // Dedicated Countdown instance pinned to the same event, so both kinds reload now;
        // see docs/22-expanded-and-dedicated-widgets.md and WidgetIntentActions.reloadAllWidgetKinds.
        #expect(reloader.reloadedKinds == [WidgetKind.kue, WidgetKind.dedicatedCountdown])
    }

    @Test func completeTaskDoesNotChangeEventStatus() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let taskA = insertTask(event, in: context, dueDate: now.addingTimeInterval(5 * 86_400))
        let taskB = insertTask(event, in: context, dueDate: now.addingTimeInterval(6 * 86_400))
        let statusBefore = event.status

        // Requirement: task/event status separation — completing *every* task on the event
        // still doesn't complete the event (docs/04 "Status transition rules").
        _ = try WidgetIntentActions.completeTask(taskID: taskA.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        _ = try WidgetIntentActions.completeTask(taskID: taskB.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        #expect(event.status == statusBefore)
        #expect(event.isManuallyCompleted == false)
    }

    @Test func completeTaskThrowsForAMissingTask() {
        let context = makeContext()
        #expect(throws: WidgetIntentError.taskNotFound) {
            try WidgetIntentActions.completeTask(taskID: UUID(), context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        }
    }

    @Test func completeTaskThrowsForAnOrphanedTask() {
        let context = makeContext()
        // A task with no `event` relationship — shouldn't occur in practice, but a stale
        // widget button tap must still be handled, not crash.
        let task = KueTask(title: "Orphan", dueDate: now, offsetLabel: "1 day before")
        context.insert(task)
        try? context.save()

        #expect(throws: WidgetIntentError.taskEventUnavailable) {
            try WidgetIntentActions.completeTask(taskID: task.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        }
    }

    // MARK: - SnoozeTaskIntent

    @Test func snoozePersistsTheNewDueDateAndOffsetLabel() async throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(30 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(3_600))

        let result = try await WidgetIntentActions.snoozeTask(taskID: task.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        #expect(task.dueDate == now.addingTimeInterval(3_600 + 86_400))
        #expect(task.dueDate == result.newDueDate)
        #expect(task.offsetLabel == result.offsetLabel)
    }

    @Test func snoozeThrowsWhenNoValidIntervalRemains() async {
        let context = makeContext()
        // Event under 30 minutes away — no room for any future due date before it.
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 60))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(-60))

        await #expect(throws: WidgetIntentError.noSnoozeIntervalRemains) {
            try await WidgetIntentActions.snoozeTask(taskID: task.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        }
    }

    @Test func snoozeReschedulesTheNotificationUnderTheSameIdentifierAtAllIntensity() async throws {
        let context = makeContext()
        UserPreferenceStore.current(context: context).notificationIntensity = .all
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(30 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(3_600))
        let identifier = "\(event.id)-task-\(task.id.uuidString)"

        let scheduler = FakeNotificationScheduler()
        _ = try await WidgetIntentActions.snoozeTask(taskID: task.id, context: context, scheduler: scheduler, widgetReloader: FakeWidgetReloader(), now: now)

        #expect(scheduler.allRemovedIdentifiers.contains(identifier)) // stale one removed first
        #expect(scheduler.addedIdentifiers.contains(identifier)) // re-added under the same id
    }

    @Test func snoozeDoesNotReaddWhenIntensityExcludesTaskDue() async throws {
        let context = makeContext()
        UserPreferenceStore.current(context: context).notificationIntensity = .standard
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(30 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(3_600))

        let scheduler = FakeNotificationScheduler()
        _ = try await WidgetIntentActions.snoozeTask(taskID: task.id, context: context, scheduler: scheduler, widgetReloader: FakeWidgetReloader(), now: now)

        #expect(scheduler.addedIdentifiers.isEmpty) // nothing to re-add at `.standard`
    }

    @Test func snoozeThrowsForAMissingTask() async {
        let context = makeContext()
        await #expect(throws: WidgetIntentError.taskNotFound) {
            try await WidgetIntentActions.snoozeTask(taskID: UUID(), context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        }
    }

    // MARK: - CompleteEventIntent

    @Test func completeEventPersistsManualCompletionAndClearsCancellation() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        event.isCancelled = true
        event.cancelledAt = now
        try? context.save()

        _ = try WidgetIntentActions.completeEvent(eventID: event.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        #expect(event.isManuallyCompleted)
        #expect(event.manuallyCompletedAt == now)
        // Requirement: preserve cancellation/manual-completion mutual exclusion.
        #expect(event.isCancelled == false)
        #expect(event.cancelledAt == nil)
    }

    @Test func completeEventRemovesEveryPendingIdentifierNotJustOne() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let task = insertTask(event, in: context, dueDate: now.addingTimeInterval(5 * 86_400))

        let scheduler = FakeNotificationScheduler()
        _ = try WidgetIntentActions.completeEvent(eventID: event.id, context: context, scheduler: scheduler, widgetReloader: FakeWidgetReloader(), now: now)

        let expected = Set(NotificationCandidateBuilder.allIdentifiers(for: event))
        #expect(expected.isSubset(of: Set(scheduler.allRemovedIdentifiers)))
        #expect(expected.contains("\(event.id)-task-\(task.id.uuidString)"))
    }

    @Test func completeEventInvokesTheInjectableWidgetReloader() throws {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        let reloader = FakeWidgetReloader()
        _ = try WidgetIntentActions.completeEvent(eventID: event.id, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: reloader, now: now)
        // Kue 2.0 Phase 8 — a mutation from either widget kind's own button can affect a
        // Dedicated Countdown instance pinned to the same event, so both kinds reload now;
        // see docs/22-expanded-and-dedicated-widgets.md and WidgetIntentActions.reloadAllWidgetKinds.
        #expect(reloader.reloadedKinds == [WidgetKind.kue, WidgetKind.dedicatedCountdown])
    }

    @Test func completeEventThrowsForAMissingEvent() {
        let context = makeContext()
        #expect(throws: WidgetIntentError.eventNotFound) {
            try WidgetIntentActions.completeEvent(eventID: UUID(), context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        }
    }
}
