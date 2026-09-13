//
//  PlanningSnapshots.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36. `KueEvent`/`KueTask` are `@Model` classes under this project's
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting, so they can't be read from a
//  background task. `SmartPlanningEngine` itself must be able to run off the main actor
//  (requirement M: "keep expensive computation off the main actor") and be tested with plain
//  values (no `ModelContext` at all) — so this file is the one, cheap, `@MainActor` copy step
//  from the live model graph into plain `nonisolated Sendable` snapshots, mirroring
//  `ScheduledTaskPlan`'s own "plain value type read off the model" precedent. Copying is a
//  handful of scalar fields per event/task, not a deep clone — negligible next to the actual
//  scoring work benchmarked in `SmartPlanningPerformanceBenchmarkTests`.
//
//  Status is captured via `EventStatusEngine.derive(for:now:)` here, once, at snapshot time —
//  never re-derived inside the engine (requirement A: "do not duplicate status derivation").
//

import Foundation
import SwiftData

nonisolated struct PlanningEventSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let eventType: EventType
    let startDate: Date
    let effectiveEndDate: Date
    let isAllDay: Bool
    let timeZoneIdentifier: String
    let priority: Priority
    /// Derived once via `EventStatusEngine.derive`, not stored `event.status` — a snapshot
    /// taken mid-sweep must reflect "what status is true right now," identical to what the
    /// engine would compute if it (wrongly) re-derived status itself.
    let status: EventStatus
    let seriesID: UUID?
    let isRecurrenceException: Bool
    let taskIDs: [UUID]
}

nonisolated struct PlanningTaskSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let eventID: UUID?
    let title: String
    let dueDate: Date
    let isCompleted: Bool
    let completedAt: Date?
    let sortOrder: Int
}

@MainActor
enum PlanningSnapshotBuilder {
    /// Excludes `.archived` events — an archived event is, by definition, something the user
    /// has already moved past; recommending anything about it would be exactly the
    /// "meaningless advice" requirement C forbids. Every other status (including `.cancelled`/
    /// `.completed`, needed so overdue-task/needs-review suppression can be verified against
    /// real terminal events rather than assumed) is included; the engine itself is what
    /// decides which statuses actually produce a recommendation.
    static func snapshot(events: [KueEvent], now: Date = .now) -> (events: [PlanningEventSnapshot], tasks: [PlanningTaskSnapshot]) {
        var eventSnapshots: [PlanningEventSnapshot] = []
        var taskSnapshots: [PlanningTaskSnapshot] = []
        eventSnapshots.reserveCapacity(events.count)

        for event in events {
            // `EventStatusEngine.derive` can never itself return `.archived` (that status
            // only ever comes from the persisted field via an explicit archive action or
            // `reconcile`'s own auto-archive step — see that file's header) — checking the
            // *derived* value here would never actually exclude anything. The persisted
            // `event.status` is the real source of truth for "already archived."
            guard event.status != .archived else { continue }
            let status = EventStatusEngine.derive(for: event, now: now)
            eventSnapshots.append(
                PlanningEventSnapshot(
                    id: event.id, title: event.title, eventType: event.eventType,
                    startDate: event.startDate, effectiveEndDate: event.effectiveEndDate,
                    isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZoneIdentifier,
                    priority: event.priority, status: status, seriesID: event.seriesID,
                    isRecurrenceException: event.isRecurrenceException,
                    taskIDs: event.tasks.map(\.id)
                )
            )
            for task in event.tasks {
                taskSnapshots.append(
                    PlanningTaskSnapshot(
                        id: task.id, eventID: event.id, title: task.title, dueDate: task.dueDate,
                        isCompleted: task.isCompleted, completedAt: task.completedAt,
                        sortOrder: task.sortOrder
                    )
                )
            }
        }
        return (eventSnapshots, taskSnapshots)
    }
}
