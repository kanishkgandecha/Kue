//
//  TaskEditingService.swift
//  Kue
//
//  Kue 3.0 Phase 1 (macOS Foundation, docs/29) — a genuine gap found while building the Mac
//  task list: no in-app UI anywhere in Kue 2.0 (iOS included) lets a user add, retitle,
//  delete, or reorder a `KueTask`, or un-complete one once marked done — every existing path
//  to "complete a task" is `WidgetIntentActions.completeTask` (widget/notification button
//  only, one-way). The Mac spec explicitly requires all of this, and nothing existing covers
//  it, so this is new, narrowly-scoped shared logic rather than a duplicate of anything —
//  reused by `MacEventDetailView`, and available to a future iOS in-app task UI without
//  rewriting. Mirrors `WidgetIntentActions.completeTask`'s own side-effect shape (bump the
//  parent event's `updatedAt`, mark the sync outbox, reload the widget) for whichever of
//  these operations plausibly affects what a widget/Live Activity shows (completion,
//  deletion); pure title/order edits don't.
//

import Foundation
import SwiftData

enum TaskEditingService {
    /// A manually added task — no schedule-rule offset, so `offsetLabel` is left blank
    /// (`KueTask.offsetLabel` already reads as "" for a rule-less task in every existing
    /// display path that already tolerates a blank subtitle).
    @discardableResult
    static func addTask(title: String, dueDate: Date, to event: KueEvent, context: ModelContext, now: Date = .now) -> KueTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOrder = (event.tasks.map(\.sortOrder).max() ?? -1) + 1
        let task = KueTask(event: event, title: trimmed, dueDate: dueDate, offsetLabel: "", sortOrder: nextOrder)
        context.insert(task)
        event.tasks.append(task)
        event.updatedAt = now
        try? context.save()
        SyncOutbox.markEventDirty(event.id)
        EventActions.reloadWidget()
        return task
    }

    static func renameTask(_ task: KueTask, title: String, context: ModelContext, now: Date = .now) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        task.title = trimmed
        task.event?.updatedAt = now
        try? context.save()
        if let eventID = task.event?.id { SyncOutbox.markEventDirty(eventID) }
    }

    /// The reverse of `WidgetIntentActions.completeTask` — nothing else in the codebase
    /// offers this, since every existing completion path is the one-way widget/notification
    /// button. Deliberately doesn't re-schedule the task-due notification that completing
    /// removed (`WidgetIntentActions.completeTask` only ever removes, never re-adds) —
    /// re-arming a stale reminder for a task the user just told Kue isn't actually done needs
    /// its own product decision, not an inferred one; noted honestly, not silently guessed at.
    static func uncompleteTask(_ task: KueTask, context: ModelContext, now: Date = .now) {
        guard task.isCompleted else { return }
        task.isCompleted = false
        task.completedAt = nil
        task.event?.updatedAt = now
        try? context.save()
        if let eventID = task.event?.id { SyncOutbox.markEventDirty(eventID) }
        EventStatusEngine.sweep(context: context, now: now)
        EventActions.reloadWidget()
    }

    static func deleteTask(
        _ task: KueTask,
        context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        now: Date = .now
    ) {
        guard let event = task.event else {
            context.delete(task)
            try? context.save()
            return
        }
        let identifier = "\(event.id)-\(NotificationTransitionKind.taskDue(taskID: task.id).identifierSuffix)"
        scheduler.removePendingNotificationRequests(withIdentifiers: [identifier])
        context.delete(task)
        event.updatedAt = now
        try? context.save()
        SyncOutbox.markEventDirty(event.id)
        EventActions.reloadWidget()
    }

    /// `orderedTasks` is the caller's full, already-reordered array (e.g. after a SwiftUI
    /// `.onMove`) — this just re-stamps `sortOrder` to match it, the same "index is the
    /// order" contract `sortedTasks` readers already assume.
    static func reorderTasks(_ orderedTasks: [KueTask], context: ModelContext) {
        for (index, task) in orderedTasks.enumerated() where task.sortOrder != index {
            task.sortOrder = index
        }
        try? context.save()
    }
}
