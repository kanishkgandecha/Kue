//
//  MigrationFixtures.swift
//  KueTests
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation, requirement 8: fixtures covering every
//  event type, all-day and timed events, completed tasks, custom schedules, widget
//  configuration, notification preferences, cancellation, manual completion, and archived
//  records. Reusable — Kue 2.0 Phase 3's `SchemaV2MigrationTests` reuses these same fixtures,
//  asserted against the *new* shape after migrating, rather than inventing a second fixture set.
//
//  Snapshot-based, not object-identity-based: after reopening a store, SwiftData hands back
//  *new* model instances, not the ones inserted — every field this file cares about is
//  captured into a plain, `Equatable`-friendly `Snapshot` at insert time, and the test
//  refetches by stable `id: UUID` from the reopened container to compare against it.
//
//  Kue 2.0 Phase 3 update: the five fixture events are now built as `KueSchemaV1.KueEvent` —
//  not the live `KueEvent` — because `MigrationTestSupport.makeV1Store` opens a store whose
//  schema only knows `KueSchemaV1.KueEvent` (see that type's own header for why V1 needed its
//  own frozen nested copy once Phase 3 changed the live `KueEvent`'s shape). Inserting a live
//  `KueEvent` into a V1-schema-only context has no matching entity descriptor and crashes —
//  this is the type every *real* V1.0 row on disk actually is, so fixtures must match it.
//

import Foundation
import SwiftData
@testable import Kue

enum MigrationFixtures {
    struct EventSnapshot {
        var id: UUID
        var title: String
        var eventType: EventType
        var startDate: Date
        var endDate: Date?
        var estimatedDurationMinutes: Int
        var isAllDay: Bool
        var timeZoneIdentifier: String
        var location: String?
        var notes: String?
        var source: EventSource
        var priority: Priority
        var status: EventStatus
        var isCancelled: Bool
        var cancelledAt: Date?
        var isManuallyCompleted: Bool
        var manuallyCompletedAt: Date?
        var hasRecurrence: Bool
        var schemaVersion: Int
        var createdAt: Date
        var updatedAt: Date
        var taskIDs: [UUID]
        var scheduleID: UUID?
        var widgetConfigurationID: UUID?
        var widgetStateID: UUID?
    }

    struct TaskSnapshot {
        var id: UUID
        var eventID: UUID?
        var title: String
        var dueDate: Date
        var isCompleted: Bool
        var completedAt: Date?
        var offsetLabel: String
        var sortOrder: Int
    }

    struct ScheduleSnapshot {
        var id: UUID
        var eventID: UUID?
        var templateType: ScheduleTemplateType
        var rules: [ScheduleRule]
        var isCustom: Bool
        var generatedAt: Date
    }

    struct WidgetConfigurationSnapshot {
        var id: UUID
        var eventID: UUID?
        var widgetType: WidgetType
        var showLocation: Bool
        var isEnabled: Bool
    }

    struct WidgetStateSnapshot {
        var id: UUID
        var eventID: UUID?
        var currentPhase: WidgetLifecyclePhase
        var headline: String
        var subline: String?
        var progress: Double?
        var nextTransitionDate: Date
    }

    struct TemplateSnapshot {
        var id: UUID
        var name: String
        var eventType: EventType
        var scheduleRules: [ScheduleRule]
        var isUserDefined: Bool
        var isBuiltIn: Bool
    }

    struct UserPreferenceSnapshot {
        var id: UUID
        var notificationIntensity: NotificationIntensity
        var aiParsingEnabled: Bool
    }

    struct Snapshot {
        var events: [EventSnapshot]
        var tasks: [TaskSnapshot]
        var schedules: [ScheduleSnapshot]
        var widgetConfigurations: [WidgetConfigurationSnapshot]
        var widgetStates: [WidgetStateSnapshot]
        var templates: [TemplateSnapshot]
        var userPreferences: [UserPreferenceSnapshot]
    }

    /// Inserts one representative row set covering every V1 event type plus every other
    /// modeled entity, and returns a `Snapshot` of exactly what was written so a caller can
    /// verify it round-trips through a reopen/migration unchanged.
    @discardableResult
    static func insertRepresentativeData(into context: ModelContext) -> Snapshot {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

        // MARK: Generic — timed, upcoming, custom schedule, one completed + one open task.
        let generic = KueSchemaV1.KueEvent(
            title: "Generic Reminder",
            eventType: .generic,
            startDate: referenceDate.addingTimeInterval(10 * 86_400),
            estimatedDurationMinutes: 0,
            isAllDay: false,
            timeZoneIdentifier: "America/New_York",
            location: "Home Office",
            notes: "Follow up notes",
            source: .manual,
            priority: .low,
            status: .upcoming,
            schemaVersion: 1
        )
        context.insert(generic)

        let genericTaskDone = KueSchemaV1.KueTask(
            event: generic, title: "Prep A", dueDate: referenceDate.addingTimeInterval(3 * 86_400),
            isCompleted: true, completedAt: referenceDate.addingTimeInterval(3 * 86_400 + 3_600),
            offsetLabel: "7 days before", sortOrder: 0
        )
        let genericTaskOpen = KueSchemaV1.KueTask(
            event: generic, title: "Prep B", dueDate: referenceDate.addingTimeInterval(9 * 86_400),
            isCompleted: false, offsetLabel: "1 day before", sortOrder: 1
        )
        context.insert(genericTaskDone)
        context.insert(genericTaskOpen)
        generic.tasks = [genericTaskDone, genericTaskOpen]

        let genericSchedule = KueSchemaV1.KueSchedule(
            event: generic,
            templateType: .custom,
            rules: [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Prep A", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Prep B", isTimeSensitive: false),
            ],
            isCustom: true,
            generatedAt: referenceDate
        )
        context.insert(genericSchedule)
        generic.schedule = genericSchedule

        let genericWidget = KueSchemaV1.WidgetConfiguration(event: generic, widgetType: .countdown, showLocation: false, isEnabled: true)
        context.insert(genericWidget)
        generic.widgetConfiguration = genericWidget

        // MARK: Deadline — all-day, cancelled.
        let deadline = KueSchemaV1.KueEvent(
            title: "Tax Filing",
            eventType: .deadline,
            startDate: referenceDate.addingTimeInterval(20 * 86_400),
            estimatedDurationMinutes: 0,
            isAllDay: true,
            timeZoneIdentifier: "UTC",
            source: .naturalLanguage,
            priority: .high,
            status: .cancelled,
            isCancelled: true,
            cancelledAt: referenceDate.addingTimeInterval(15 * 86_400),
            schemaVersion: 1
        )
        context.insert(deadline)

        let deadlineTask = KueSchemaV1.KueTask(
            event: deadline, title: "Gather documents", dueDate: referenceDate.addingTimeInterval(13 * 86_400),
            isCompleted: false, offsetLabel: "7 days before", sortOrder: 0
        )
        context.insert(deadlineTask)
        deadline.tasks = [deadlineTask]

        let deadlineSchedule = KueSchemaV1.KueSchedule(
            event: deadline, templateType: .deadline,
            rules: [ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Gather documents", isTimeSensitive: false)],
            isCustom: false, generatedAt: referenceDate
        )
        context.insert(deadlineSchedule)
        deadline.schedule = deadlineSchedule

        let deadlineWidget = KueSchemaV1.WidgetConfiguration(event: deadline, widgetType: .preparation)
        context.insert(deadlineWidget)
        deadline.widgetConfiguration = deadlineWidget

        // MARK: Exam — timed, manually completed, three tasks with distinct sort order.
        let exam = KueSchemaV1.KueEvent(
            title: "OS Final",
            eventType: .exam,
            startDate: referenceDate.addingTimeInterval(5 * 86_400),
            estimatedDurationMinutes: 120,
            isAllDay: false,
            timeZoneIdentifier: "Asia/Tokyo",
            source: .shareSheet,
            priority: .medium,
            status: .completed,
            isManuallyCompleted: true,
            manuallyCompletedAt: referenceDate.addingTimeInterval(4 * 86_400),
            schemaVersion: 1
        )
        context.insert(exam)

        let examTasks = [
            KueSchemaV1.KueTask(event: exam, title: "Chapter 1-3", dueDate: referenceDate.addingTimeInterval(1 * 86_400), isCompleted: true, completedAt: referenceDate, offsetLabel: "14 days before", sortOrder: 0),
            KueSchemaV1.KueTask(event: exam, title: "Chapter 4-6", dueDate: referenceDate.addingTimeInterval(2 * 86_400), isCompleted: true, completedAt: referenceDate, offsetLabel: "7 days before", sortOrder: 1),
            KueSchemaV1.KueTask(event: exam, title: "Revision", dueDate: referenceDate.addingTimeInterval(4 * 86_400), isCompleted: false, offsetLabel: "1 day before", sortOrder: 2),
        ]
        for task in examTasks { context.insert(task) }
        exam.tasks = examTasks

        let examWidget = KueSchemaV1.WidgetConfiguration(event: exam, widgetType: .progress, showLocation: true, isEnabled: true)
        context.insert(examWidget)
        exam.widgetConfiguration = examWidget

        // MARK: Interview — timed, archived, widget disabled, WidgetState populated.
        let interview = KueSchemaV1.KueEvent(
            title: "Salesforce Interview",
            eventType: .interview,
            startDate: referenceDate.addingTimeInterval(-2 * 86_400),
            estimatedDurationMinutes: 60,
            isAllDay: false,
            timeZoneIdentifier: "America/Los_Angeles",
            location: "123 Market St",
            source: .manual,
            priority: .high,
            status: .archived,
            schemaVersion: 1
        )
        context.insert(interview)

        let interviewWidget = KueSchemaV1.WidgetConfiguration(event: interview, widgetType: .checklist, isEnabled: false)
        context.insert(interviewWidget)
        interview.widgetConfiguration = interviewWidget

        let interviewWidgetState = KueSchemaV1.WidgetState(
            event: interview, currentPhase: .completed, headline: "Salesforce Interview",
            subline: "Completed", progress: 0.5, nextTransitionDate: referenceDate.addingTimeInterval(86_400)
        )
        context.insert(interviewWidgetState)
        interview.widgetState = interviewWidgetState

        // MARK: Trip — timed, has endDate, time-sensitive rule (DateComponents round trip).
        let trip = KueSchemaV1.KueEvent(
            title: "Tokyo Trip",
            eventType: .trip,
            startDate: referenceDate.addingTimeInterval(30 * 86_400),
            endDate: referenceDate.addingTimeInterval(37 * 86_400),
            estimatedDurationMinutes: 0,
            isAllDay: false,
            timeZoneIdentifier: "Asia/Tokyo",
            location: "Tokyo, Japan",
            notes: nil,
            source: .manual,
            priority: .medium,
            status: .upcoming,
            schemaVersion: 1
        )
        context.insert(trip)

        let tripSchedule = KueSchemaV1.KueSchedule(
            event: trip, templateType: .trip,
            rules: [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Countdown start", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(hour: 3), taskTitle: "Departure", isTimeSensitive: true),
            ],
            isCustom: false, generatedAt: referenceDate
        )
        context.insert(tripSchedule)
        trip.schedule = tripSchedule

        let tripWidget = KueSchemaV1.WidgetConfiguration(event: trip, widgetType: .timeline)
        context.insert(tripWidget)
        trip.widgetConfiguration = tripWidget

        // MARK: Template (never actually populated by V1 product code, but part of the
        // schema — verified for completeness, requirement 7's "every field and relationship").
        // `KueSchemaV1.Template`, not the live type — see this file's header ("inserting a live
        // KueEvent into a V1-schema-only context ... crashes") and `KueSchemaV1.swift`'s Phase 3
        // completion-pass correction: `Template` gained a new stored property, so the live
        // symbol no longer matches this schema's own frozen shape.
        let template = KueSchemaV1.Template(
            name: "Interview", eventType: .interview,
            scheduleRules: [ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Preparation start", isTimeSensitive: false)],
            isUserDefined: false, isBuiltIn: true
        )
        context.insert(template)

        // MARK: UserPreference — non-default values, so a snapshot mismatch can't hide
        // behind "it happened to match the default anyway."
        let preference = UserPreference(notificationIntensity: .all, aiParsingEnabled: false)
        context.insert(preference)

        try? context.save()

        return Snapshot(
            events: [
                snapshot(generic), snapshot(deadline), snapshot(exam), snapshot(interview), snapshot(trip),
            ],
            tasks: (generic.tasks + deadline.tasks + exam.tasks).map(snapshot),
            schedules: [genericSchedule, deadlineSchedule, tripSchedule].map(snapshot),
            widgetConfigurations: [genericWidget, deadlineWidget, examWidget, interviewWidget, tripWidget].map(snapshot),
            widgetStates: [interviewWidgetState].map(snapshot),
            templates: [snapshot(template)],
            userPreferences: [snapshot(preference)]
        )
    }

    // MARK: - Snapshot builders

    /// Kue 2.0 Phase 3 — the fixtures themselves are `KueSchemaV1.KueEvent` (see file header),
    /// but its fields are identical to live `KueEvent`'s V1-era fields, so this overload is a
    /// plain mechanical copy of the one below it.
    ///
    /// `hasRecurrence` is hardcoded `false`: `KueSchemaV1.KueEvent` doesn't declare
    /// `recurrence` at all (real V1.0 rows have no `ZRECURRENCE` column — see
    /// `KueSchemaV1.swift`'s header), so there's nothing to read here. `verifyEvents` below
    /// still checks the *migrated* event's `recurrence == nil` against this, proving the
    /// V1→V2 backfill actually ran.
    private static func snapshot(_ event: KueSchemaV1.KueEvent) -> EventSnapshot {
        EventSnapshot(
            id: event.id, title: event.title, eventType: event.eventType, startDate: event.startDate,
            endDate: event.endDate, estimatedDurationMinutes: event.estimatedDurationMinutes, isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier, location: event.location, notes: event.notes,
            source: event.source, priority: event.priority, status: event.status, isCancelled: event.isCancelled,
            cancelledAt: event.cancelledAt, isManuallyCompleted: event.isManuallyCompleted,
            manuallyCompletedAt: event.manuallyCompletedAt, hasRecurrence: false,
            schemaVersion: event.schemaVersion, createdAt: event.createdAt, updatedAt: event.updatedAt,
            taskIDs: event.tasks.map(\.id).sorted(), scheduleID: event.schedule?.id,
            widgetConfigurationID: event.widgetConfiguration?.id, widgetStateID: event.widgetState?.id
        )
    }

    private static func snapshot(_ task: KueSchemaV1.KueTask) -> TaskSnapshot {
        TaskSnapshot(
            id: task.id, eventID: task.event?.id, title: task.title, dueDate: task.dueDate,
            isCompleted: task.isCompleted, completedAt: task.completedAt, offsetLabel: task.offsetLabel,
            sortOrder: task.sortOrder
        )
    }

    private static func snapshot(_ schedule: KueSchemaV1.KueSchedule) -> ScheduleSnapshot {
        ScheduleSnapshot(
            id: schedule.id, eventID: schedule.event?.id, templateType: schedule.templateType,
            rules: schedule.rules, isCustom: schedule.isCustom, generatedAt: schedule.generatedAt
        )
    }

    private static func snapshot(_ configuration: KueSchemaV1.WidgetConfiguration) -> WidgetConfigurationSnapshot {
        WidgetConfigurationSnapshot(
            id: configuration.id, eventID: configuration.event?.id, widgetType: configuration.widgetType,
            showLocation: configuration.showLocation, isEnabled: configuration.isEnabled
        )
    }

    private static func snapshot(_ state: KueSchemaV1.WidgetState) -> WidgetStateSnapshot {
        WidgetStateSnapshot(
            id: state.id, eventID: state.event?.id, currentPhase: state.currentPhase, headline: state.headline,
            subline: state.subline, progress: state.progress, nextTransitionDate: state.nextTransitionDate
        )
    }

    private static func snapshot(_ template: KueSchemaV1.Template) -> TemplateSnapshot {
        TemplateSnapshot(
            id: template.id, name: template.name, eventType: template.eventType,
            scheduleRules: template.scheduleRules, isUserDefined: template.isUserDefined, isBuiltIn: template.isBuiltIn
        )
    }

    private static func snapshot(_ preference: UserPreference) -> UserPreferenceSnapshot {
        UserPreferenceSnapshot(
            id: preference.id, notificationIntensity: preference.notificationIntensity,
            aiParsingEnabled: preference.aiParsingEnabled
        )
    }
}
