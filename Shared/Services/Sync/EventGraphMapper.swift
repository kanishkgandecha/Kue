//
//  EventGraphMapper.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "C." The only place `EventSyncRecord`
//  crosses into/out of the real SwiftData `KueEvent`/`KueTask`/`KueSchedule`/
//  `WidgetConfiguration` models. Pure with respect to CloudKit (no `import CloudKit`
//  anywhere in this file) — it only ever reads/writes already-fetched `@Model` instances the
//  caller supplies, never touches `ModelContext` itself (insert/delete/save stay the caller's
//  responsibility, same separation `EventActions`/`WidgetIntentActions` already establish
//  between "compute the change" and "persist it").
//

import Foundation
import SwiftData

nonisolated enum EventGraphMapper {
    /// Builds the record this event's *entire local graph* would upload as. Deliberately
    /// excludes every `externalCalendar*` field (docs/26 "D." — device-local, no
    /// cross-device EKEvent identity guarantee) and every device-local model (`WidgetState`,
    /// `UserPreference`) that never had a place in `EventSyncRecord` to begin with.
    static func record(for event: KueEvent) -> EventSyncRecord {
        EventSyncRecord(
            id: event.id,
            title: event.title,
            eventType: event.eventType.rawValue,
            startDate: event.startDate,
            endDate: event.endDate,
            estimatedDurationMinutes: event.estimatedDurationMinutes,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: event.location,
            notes: event.notes,
            source: event.source.rawValue,
            priority: event.priority.rawValue,
            isCancelled: event.isCancelled,
            cancelledAt: event.cancelledAt,
            isManuallyCompleted: event.isManuallyCompleted,
            manuallyCompletedAt: event.manuallyCompletedAt,
            recurrence: event.recurrence.map(recurrencePayload),
            seriesID: event.seriesID,
            recurrenceAnchorDate: event.recurrenceAnchorDate,
            isRecurrenceException: event.isRecurrenceException,
            isSkipped: event.isSkipped,
            skippedAt: event.skippedAt,
            tasks: event.tasks.map(taskPayload).sorted { $0.sortOrder < $1.sortOrder },
            schedule: event.schedule.map(schedulePayload),
            widgetConfiguration: event.widgetConfiguration.map(widgetConfigurationPayload),
            createdAt: event.createdAt,
            updatedAt: event.updatedAt
        )
    }

    /// Constructs a brand-new, not-yet-inserted `KueEvent` (with its full child graph) from a
    /// downloaded record — used only when the record's `id` doesn't match any local event yet.
    /// The caller is responsible for `context.insert(_:)`.
    static func makeEvent(from record: EventSyncRecord) -> KueEvent {
        let event = KueEvent(
            id: record.id,
            title: record.title,
            eventType: EventType(rawValue: record.eventType) ?? .generic,
            startDate: record.startDate,
            endDate: record.endDate,
            estimatedDurationMinutes: record.estimatedDurationMinutes,
            isAllDay: record.isAllDay,
            timeZoneIdentifier: record.timeZoneIdentifier,
            location: record.location,
            notes: record.notes,
            source: EventSource(rawValue: record.source) ?? .manual,
            priority: Priority(rawValue: record.priority) ?? .medium,
            isCancelled: record.isCancelled,
            cancelledAt: record.cancelledAt,
            isManuallyCompleted: record.isManuallyCompleted,
            manuallyCompletedAt: record.manuallyCompletedAt,
            recurrence: record.recurrence.map(recurrenceRule),
            seriesID: record.seriesID,
            recurrenceAnchorDate: record.recurrenceAnchorDate,
            isRecurrenceException: record.isRecurrenceException,
            isSkipped: record.isSkipped,
            skippedAt: record.skippedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
        // `EventStatusEngine.derive` recomputes `status` from these inputs the next
        // reconciliation pass (docs/26 "I."); the freshly-constructed default (`.upcoming`)
        // is a safe placeholder until then, same as any other newly-created event.
        event.tasks = record.tasks.map { makeTask(from: $0, event: event) }
        if let schedule = record.schedule {
            event.schedule = makeSchedule(from: schedule, event: event)
        }
        if let widgetConfiguration = record.widgetConfiguration {
            event.widgetConfiguration = makeWidgetConfiguration(from: widgetConfiguration, event: event)
        }
        return event
    }

    /// Overwrites `event`'s entire local graph to match `record` — only ever called once the
    /// conflict resolver has already decided the *remote* side wins this event outright
    /// (docs/26 "H.": whole-graph resolution, never field-by-field). Reconstructs children by
    /// stable UUID: an existing local task/schedule/widget config whose id matches is updated
    /// in place (preserving SwiftData identity); one that only exists in `record` is newly
    /// inserted; one that only exists locally is removed — the remote graph becomes the
    /// complete truth for this event. Never touches `externalCalendar*` fields (device-local).
    ///
    /// Returns the local `KueTask`s this call orphaned (present locally, absent from
    /// `record.tasks`) — their `event` back-reference no longer points anywhere meaningful
    /// once `mergedTasks` replaces `event.tasks` below, but SwiftData's cascade inverse
    /// doesn't auto-delete an orphan, so the caller (`SyncCoordinator`, which owns the
    /// `ModelContext` this pure mapper deliberately never touches) must `context.delete(_:)`
    /// each one explicitly.
    @discardableResult
    static func apply(_ record: EventSyncRecord, to event: KueEvent) -> [KueTask] {
        event.title = record.title
        event.eventType = EventType(rawValue: record.eventType) ?? .generic
        event.startDate = record.startDate
        event.endDate = record.endDate
        event.estimatedDurationMinutes = record.estimatedDurationMinutes
        event.isAllDay = record.isAllDay
        event.timeZoneIdentifier = record.timeZoneIdentifier
        event.location = record.location
        event.notes = record.notes
        event.source = EventSource(rawValue: record.source) ?? .manual
        event.priority = Priority(rawValue: record.priority) ?? .medium
        event.isCancelled = record.isCancelled
        event.cancelledAt = record.cancelledAt
        event.isManuallyCompleted = record.isManuallyCompleted
        event.manuallyCompletedAt = record.manuallyCompletedAt
        event.recurrence = record.recurrence.map(recurrenceRule)
        event.seriesID = record.seriesID
        event.recurrenceAnchorDate = record.recurrenceAnchorDate
        event.isRecurrenceException = record.isRecurrenceException
        event.isSkipped = record.isSkipped
        event.skippedAt = record.skippedAt
        event.createdAt = record.createdAt
        event.updatedAt = record.updatedAt

        var remainingLocalTasks = Dictionary(uniqueKeysWithValues: event.tasks.map { ($0.id, $0) })
        var mergedTasks: [KueTask] = []
        for payload in record.tasks {
            if let existing = remainingLocalTasks.removeValue(forKey: payload.id) {
                apply(payload, to: existing)
                mergedTasks.append(existing)
            } else {
                mergedTasks.append(makeTask(from: payload, event: event))
            }
        }
        event.tasks = mergedTasks

        if let payload = record.schedule {
            if let existing = event.schedule {
                apply(payload, to: existing)
            } else {
                event.schedule = makeSchedule(from: payload, event: event)
            }
        } else {
            event.schedule = nil
        }

        if let payload = record.widgetConfiguration {
            if let existing = event.widgetConfiguration {
                apply(payload, to: existing)
            } else {
                event.widgetConfiguration = makeWidgetConfiguration(from: payload, event: event)
            }
        } else {
            event.widgetConfiguration = nil
        }

        return Array(remainingLocalTasks.values)
    }

    // MARK: - RecurrenceExclusion

    static func record(for exclusion: RecurrenceExclusion) -> RecurrenceExclusionSyncRecord {
        RecurrenceExclusionSyncRecord(id: exclusion.id, seriesID: exclusion.seriesID, excludedAnchorDate: exclusion.excludedAnchorDate)
    }

    static func makeExclusion(from record: RecurrenceExclusionSyncRecord) -> RecurrenceExclusion {
        RecurrenceExclusion(id: record.id, seriesID: record.seriesID, excludedAnchorDate: record.excludedAnchorDate)
    }

    // MARK: - Child payload helpers

    private static func taskPayload(_ task: KueTask) -> TaskSyncPayload {
        TaskSyncPayload(id: task.id, title: task.title, dueDate: task.dueDate, isCompleted: task.isCompleted, completedAt: task.completedAt, offsetLabel: task.offsetLabel, sortOrder: task.sortOrder)
    }

    private static func makeTask(from payload: TaskSyncPayload, event: KueEvent) -> KueTask {
        KueTask(id: payload.id, event: event, title: payload.title, dueDate: payload.dueDate, isCompleted: payload.isCompleted, completedAt: payload.completedAt, offsetLabel: payload.offsetLabel, sortOrder: payload.sortOrder)
    }

    private static func apply(_ payload: TaskSyncPayload, to task: KueTask) {
        task.title = payload.title
        task.dueDate = payload.dueDate
        task.isCompleted = payload.isCompleted
        task.completedAt = payload.completedAt
        task.offsetLabel = payload.offsetLabel
        task.sortOrder = payload.sortOrder
    }

    private static func schedulePayload(_ schedule: KueSchedule) -> SchedulePayload {
        SchedulePayload(
            id: schedule.id,
            templateType: schedule.templateType.rawValue,
            rules: schedule.rules.map { ScheduleRulePayload(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) },
            isCustom: schedule.isCustom,
            generatedAt: schedule.generatedAt
        )
    }

    private static func makeSchedule(from payload: SchedulePayload, event: KueEvent) -> KueSchedule {
        KueSchedule(
            id: payload.id, event: event,
            templateType: ScheduleTemplateType(rawValue: payload.templateType) ?? .custom,
            rules: payload.rules.map { ScheduleRule(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) },
            isCustom: payload.isCustom, generatedAt: payload.generatedAt
        )
    }

    private static func apply(_ payload: SchedulePayload, to schedule: KueSchedule) {
        schedule.templateType = ScheduleTemplateType(rawValue: payload.templateType) ?? .custom
        schedule.rules = payload.rules.map { ScheduleRule(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) }
        schedule.isCustom = payload.isCustom
        schedule.generatedAt = payload.generatedAt
    }

    private static func widgetConfigurationPayload(_ configuration: WidgetConfiguration) -> WidgetConfigurationPayload {
        WidgetConfigurationPayload(id: configuration.id, widgetType: configuration.widgetType.rawValue, showLocation: configuration.showLocation, isEnabled: configuration.isEnabled)
    }

    private static func makeWidgetConfiguration(from payload: WidgetConfigurationPayload, event: KueEvent) -> WidgetConfiguration {
        WidgetConfiguration(id: payload.id, event: event, widgetType: WidgetType(rawValue: payload.widgetType) ?? .countdown, showLocation: payload.showLocation, isEnabled: payload.isEnabled)
    }

    private static func apply(_ payload: WidgetConfigurationPayload, to configuration: WidgetConfiguration) {
        configuration.widgetType = WidgetType(rawValue: payload.widgetType) ?? .countdown
        configuration.showLocation = payload.showLocation
        configuration.isEnabled = payload.isEnabled
    }

    private static func recurrencePayload(_ rule: RecurrenceRule) -> RecurrenceRulePayload {
        switch rule.end {
        case .never:
            return RecurrenceRulePayload(frequency: rule.frequency.rawValue, interval: rule.interval, endKind: "never", endDate: nil, endOccurrenceCount: nil)
        case .onDate(let date):
            return RecurrenceRulePayload(frequency: rule.frequency.rawValue, interval: rule.interval, endKind: "onDate", endDate: date, endOccurrenceCount: nil)
        case .afterOccurrences(let count):
            return RecurrenceRulePayload(frequency: rule.frequency.rawValue, interval: rule.interval, endKind: "afterOccurrences", endDate: nil, endOccurrenceCount: count)
        }
    }

    private static func recurrenceRule(_ payload: RecurrenceRulePayload) -> RecurrenceRule {
        let end: RecurrenceRule.End
        switch payload.endKind {
        case "onDate":
            end = .onDate(payload.endDate ?? .now)
        case "afterOccurrences":
            end = .afterOccurrences(payload.endOccurrenceCount ?? 1)
        default:
            end = .never // Kue 2.0 Phase 11 — docs/26 "O." unknown/future kind falls back safely.
        }
        return RecurrenceRule(frequency: RecurrenceRule.Frequency(rawValue: payload.frequency) ?? .weekly, interval: max(payload.interval, 1), end: end)
    }
}
