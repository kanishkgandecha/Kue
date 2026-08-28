//
//  EventGraphMapperTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26 "S." 14/15/16/17 — parent-deletion/orphan prevention, task/
//  schedule reconstruction by stable UUID, recurring-occurrence identity.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct EventGraphMapperTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func recordCapturesTasksScheduleAndWidgetConfiguration() {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now, estimatedDurationMinutes: 60, source: .manual)
        let task = KueTask(event: event, title: "Prepare", dueDate: now, offsetLabel: "1 day before")
        event.tasks = [task]
        event.schedule = KueSchedule(event: event, templateType: .interview, rules: [ScheduleRule(offset: DateComponents(day: -1), taskTitle: "Prepare", isTimeSensitive: false)])
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .preparation)

        let record = EventGraphMapper.record(for: event)
        #expect(record.tasks.count == 1)
        #expect(record.tasks.first?.id == task.id)
        #expect(record.schedule?.rules.count == 1)
        #expect(record.widgetConfiguration?.widgetType == "preparation")
    }

    @Test func externalCalendarFieldsAreNeverIncludedInTheSyncedRecord() {
        // docs/26 "D." — device-local, never synced.
        let event = KueEvent(
            title: "Linked", eventType: .generic, startDate: now, estimatedDurationMinutes: 0, source: .calendarImport,
            externalCalendarEventIdentifier: "ek-123", externalCalendarIdentifier: "cal-1", externalCalendarTitle: "Home"
        )
        let record = EventGraphMapper.record(for: event)
        // `EventSyncRecord` has no external-calendar fields at all — this is a compile-time
        // guarantee, not a runtime one, but this test documents the intent explicitly and
        // exercises the mapper against a Calendar-imported fixture.
        #expect(record.source == "calendarImport")
    }

    @Test func makeEventReconstructsTheFullGraphWithStableChildIdentity() {
        let taskID = UUID()
        let record = EventSyncRecord(
            id: UUID(), title: "Exam", eventType: "exam", startDate: now, endDate: nil,
            estimatedDurationMinutes: 120, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil,
            tasks: [TaskSyncPayload(id: taskID, title: "Study", dueDate: now, isCompleted: false, completedAt: nil, offsetLabel: "2 days before", sortOrder: 0)],
            schedule: nil, widgetConfiguration: nil, createdAt: now, updatedAt: now
        )
        let event = EventGraphMapper.makeEvent(from: record)
        #expect(event.id == record.id)
        #expect(event.tasks.count == 1)
        #expect(event.tasks.first?.id == taskID)
        #expect(event.tasks.first?.event?.id == event.id)
    }

    // MARK: 14/15 — parent deletion / orphan prevention, task reconstruction by UUID

    @Test func applyReconstructsTasksByUUIDAndOrphansRemovedOnes() {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now, estimatedDurationMinutes: 60, source: .manual)
        let keptTask = KueTask(event: event, title: "Keep", dueDate: now, offsetLabel: "1 day before")
        let removedTask = KueTask(event: event, title: "Remove", dueDate: now, offsetLabel: "2 days before")
        event.tasks = [keptTask, removedTask]

        let updatedTaskPayload = TaskSyncPayload(id: keptTask.id, title: "Keep (edited)", dueDate: now, isCompleted: true, completedAt: now, offsetLabel: "1 day before", sortOrder: 0)
        let newTaskPayload = TaskSyncPayload(id: UUID(), title: "New from remote", dueDate: now, isCompleted: false, completedAt: nil, offsetLabel: "3 days before", sortOrder: 1)
        let record = EventSyncRecord(
            id: event.id, title: "Interview", eventType: "interview", startDate: now, endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil,
            tasks: [updatedTaskPayload, newTaskPayload], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now.addingTimeInterval(100)
        )

        let orphaned = EventGraphMapper.apply(record, to: event)

        #expect(orphaned.count == 1)
        #expect(orphaned.first?.id == removedTask.id)
        #expect(event.tasks.count == 2)
        // `keptTask` is the *same* SwiftData object, updated in place — identity preserved.
        #expect(event.tasks.contains { $0.id == keptTask.id && $0.title == "Keep (edited)" && $0.isCompleted })
        #expect(event.tasks.contains { $0.id == newTaskPayload.id })
        #expect(keptTask.title == "Keep (edited)") // same object instance mutated, not replaced
    }

    @Test func applyRemovesScheduleAndWidgetConfigurationWhenAbsentFromRecord() {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now, estimatedDurationMinutes: 60, source: .manual)
        event.schedule = KueSchedule(event: event, templateType: .interview)
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .preparation)

        let record = EventSyncRecord(
            id: event.id, title: "Interview", eventType: "interview", startDate: now, endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now.addingTimeInterval(100)
        )
        _ = EventGraphMapper.apply(record, to: event)
        #expect(event.schedule == nil)
        #expect(event.widgetConfiguration == nil)
    }

    // MARK: 16 — schedule-rule reconstruction

    @Test func applyReconstructsScheduleRulesFromThePayload() {
        let event = KueEvent(title: "Exam", eventType: .exam, startDate: now, estimatedDurationMinutes: 120, source: .manual)
        let record = EventSyncRecord(
            id: event.id, title: "Exam", eventType: "exam", startDate: now, endDate: nil,
            estimatedDurationMinutes: 120, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [],
            schedule: SchedulePayload(id: UUID(), templateType: "exam", rules: [ScheduleRulePayload(offset: DateComponents(day: -3), taskTitle: "Review", isTimeSensitive: false)], isCustom: false, generatedAt: now),
            widgetConfiguration: nil, createdAt: now, updatedAt: now.addingTimeInterval(100)
        )
        _ = EventGraphMapper.apply(record, to: event)
        #expect(event.schedule?.rules.count == 1)
        #expect(event.schedule?.rules.first?.taskTitle == "Review")
    }

    // MARK: 17 — recurring occurrence identity

    @Test func siblingOccurrencesInTheSameSeriesKeepDistinctRecordIdentity() {
        let seriesID = UUID()
        let occurrenceA = KueEvent(title: "Standup", eventType: .generic, startDate: now, estimatedDurationMinutes: 30, source: .manual, seriesID: seriesID, recurrenceAnchorDate: now)
        let occurrenceB = KueEvent(title: "Standup", eventType: .generic, startDate: now.addingTimeInterval(7 * 86_400), estimatedDurationMinutes: 30, source: .manual, seriesID: seriesID, recurrenceAnchorDate: now.addingTimeInterval(7 * 86_400))

        let recordA = EventGraphMapper.record(for: occurrenceA)
        let recordB = EventGraphMapper.record(for: occurrenceB)
        #expect(recordA.id != recordB.id) // each materialized row is its own record
        #expect(recordA.seriesID == recordB.seriesID) // same series, distinct identity
    }
}
