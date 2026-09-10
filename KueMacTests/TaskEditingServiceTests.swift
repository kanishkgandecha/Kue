//
//  TaskEditingServiceTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 — `TaskEditingService` (Shared/) is new code (see its own header: no
//  in-app task add/rename/delete/reorder/uncomplete existed anywhere in Kue before this
//  phase), so unlike most of `Shared/`, it has no existing `KueTests` coverage to lean on —
//  this is its first test coverage, deliberately placed here since it was built for the Mac
//  task list, though the service itself is reachable from iOS too.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all four files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    /// Returns `container` too, not just `context`/`event` — `ModelContext` doesn't keep its
    /// own strong reference back to the `ModelContainer` that vended it, so a caller that lets
    /// `container` go out of scope while still using `context` risks the container (and the
    /// context's backing store) being deallocated out from under it. Every call site below
    /// holds `container` for its own duration precisely to avoid that.
    private func makeContext() -> (container: ModelContainer, context: ModelContext, event: KueEvent) {
        let container = MacTestSupport.makeTestContainer()
        let context = container.mainContext
        let event = MacTestSupport.makeFixtureEvent()
        context.insert(event)
        try? context.save()
        return (container, context, event)
    }

    @Test func addTaskAppendsToTheEventWithTheNextSortOrder() {
        let (container, context, event) = makeContext()
        let due = event.startDate
        _ = TaskEditingService.addTask(title: "First", dueDate: due, to: event, context: context)
        let second = TaskEditingService.addTask(title: "Second", dueDate: due, to: event, context: context)
        #expect(event.tasks.count == 2)
        #expect(second.sortOrder == 1)
        _ = container
    }

    @Test func addTaskTrimsWhitespaceFromTheTitle() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "  Padded  ", dueDate: event.startDate, to: event, context: context)
        #expect(task.title == "Padded")
        _ = container
    }

    @Test func renameTaskUpdatesTheTitleAndBumpsTheEventsUpdatedAt() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "Original", dueDate: event.startDate, to: event, context: context)
        let before = event.updatedAt
        TaskEditingService.renameTask(task, title: "Renamed", context: context)
        #expect(task.title == "Renamed")
        #expect(event.updatedAt >= before)
        _ = container
    }

    @Test func renameTaskToBlankIsRejected() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "Keep Me", dueDate: event.startDate, to: event, context: context)
        TaskEditingService.renameTask(task, title: "   ", context: context)
        #expect(task.title == "Keep Me")
        _ = container
    }

    @Test func uncompleteTaskReversesCompletionAndClearsCompletedAt() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "Task", dueDate: event.startDate, to: event, context: context)
        task.isCompleted = true
        task.completedAt = .now
        TaskEditingService.uncompleteTask(task, context: context)
        #expect(task.isCompleted == false)
        #expect(task.completedAt == nil)
        _ = container
    }

    @Test func uncompleteTaskIsANoOpOnAnAlreadyIncompleteTask() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "Task", dueDate: event.startDate, to: event, context: context)
        let before = event.updatedAt
        TaskEditingService.uncompleteTask(task, context: context)
        #expect(event.updatedAt == before)
        _ = container
    }

    @Test func deleteTaskRemovesItFromTheEvent() {
        let (container, context, event) = makeContext()
        let task = TaskEditingService.addTask(title: "Doomed", dueDate: event.startDate, to: event, context: context)
        TaskEditingService.deleteTask(task, context: context)
        #expect(event.tasks.isEmpty)
        _ = container
    }

    @Test func reorderTasksReassignsSortOrderToMatchTheGivenArray() {
        let (container, context, event) = makeContext()
        let a = TaskEditingService.addTask(title: "A", dueDate: event.startDate, to: event, context: context)
        let b = TaskEditingService.addTask(title: "B", dueDate: event.startDate, to: event, context: context)
        let c = TaskEditingService.addTask(title: "C", dueDate: event.startDate, to: event, context: context)
        let orders: [Int] = [a.sortOrder, b.sortOrder, c.sortOrder]
        #expect(orders == [0, 1, 2])

        TaskEditingService.reorderTasks([c, a, b], context: context)
        #expect(c.sortOrder == 0)
        #expect(a.sortOrder == 1)
        #expect(b.sortOrder == 2)
        _ = container
    }
}
