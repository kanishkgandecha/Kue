//
//  KueSchemaV2.swift
//  Kue
//
//  Kue 2.0 Phase 3 — Recurring Events. See docs/17-recurring-events.md "Migration" and
//  docs/15-schema-migrations.md "How to add a schema version."
//
//  `KueEvent` gained six new stored properties this phase (`recurrence`, `seriesID`,
//  `recurrenceAnchorDate`, `isRecurrenceException`, `isSkipped`, `skippedAt` — see
//  Shared/Models/KueEvent.swift) and a new model, `RecurrenceExclusion`, was added to the
//  schema entirely.
//
//  Correction (2026-08-27): `recurrence` was originally believed to already exist in V1.0 (a
//  "reserved, always nil" field) and so wasn't in this list. It never actually shipped in
//  V1.0 — see `KueSchemaV1.swift`'s header for the real-store incident this was found from —
//  so it genuinely belongs here, backfilled to `nil` by `KueMigrationPlan.migrateV1toV2`
//  alongside the other five.
//
//  Kue 2.0 Phase 4 update (docs/18-calendar-integration.md "Migration"): Phase 4 changed
//  `KueEvent`'s shape *again* (five new Calendar-linkage fields), which means the live
//  `KueEvent` symbol now means the Phase-4 shape, not this schema's own. Exactly the same
//  situation `KueSchemaV1.swift` documents at length — see that file's header for the full
//  reasoning — applies here: `KueEvent` (at its Phase-3-era shape, immediately before Phase 4)
//  is nested as `KueSchemaV2.KueEvent`, and so is every type with a `@Relationship` *to* it
//  (`KueTask`, `KueSchedule`, `WidgetConfiguration`, `WidgetState`), each pointing at its
//  nested siblings so the whole connected subgraph stays internally consistent.
//  `RecurrenceExclusion` has no relationship to `KueEvent` (just a plain `seriesID: UUID`), so
//  — like `Template`/`UserPreference` — it's still an untouched island in the graph and keeps
//  referencing the live, shared type directly.
//

import SwiftData
import Foundation

enum KueSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            KueEvent.self,
            RecurrenceExclusion.self,
            KueTask.self,
            KueSchedule.self,
            WidgetConfiguration.self,
            WidgetState.self,
            Template.self,
            UserPreference.self,
        ]
    }

    /// Exact copy of `Shared/Models/KueTask.swift` as it stood before Kue 2.0 Phase 4, except
    /// `event` now points at the nested `KueSchemaV2.KueEvent` sibling instead of the live one
    /// — see file header.
    @Model
    final class KueTask {
        var id: UUID
        var event: KueEvent?
        var title: String
        var dueDate: Date
        var isCompleted: Bool
        var completedAt: Date?
        var offsetLabel: String
        var sortOrder: Int

        init(
            id: UUID = UUID(),
            event: KueEvent? = nil,
            title: String,
            dueDate: Date,
            isCompleted: Bool = false,
            completedAt: Date? = nil,
            offsetLabel: String,
            sortOrder: Int = 0
        ) {
            self.id = id
            self.event = event
            self.title = title
            self.dueDate = dueDate
            self.isCompleted = isCompleted
            self.completedAt = completedAt
            self.offsetLabel = offsetLabel
            self.sortOrder = sortOrder
        }
    }

    /// Exact copy of `Shared/Models/KueSchedule.swift` as it stood before Kue 2.0 Phase 4 — see
    /// file header (event points at the nested sibling).
    @Model
    final class KueSchedule {
        var id: UUID
        var event: KueEvent?
        var templateType: ScheduleTemplateType
        private var rulesData: Data
        var isCustom: Bool
        var generatedAt: Date

        var rules: [ScheduleRule] {
            get { (try? JSONDecoder().decode([ScheduleRule].self, from: rulesData)) ?? [] }
            set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
        }

        init(
            id: UUID = UUID(),
            event: KueEvent? = nil,
            templateType: ScheduleTemplateType,
            rules: [ScheduleRule] = [],
            isCustom: Bool = false,
            generatedAt: Date = Date()
        ) {
            self.id = id
            self.event = event
            self.templateType = templateType
            self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
            self.isCustom = isCustom
            self.generatedAt = generatedAt
        }
    }

    /// Exact copy of `Shared/Models/WidgetConfiguration.swift` as it stood before Kue 2.0
    /// Phase 4 — see file header (event points at the nested sibling).
    @Model
    final class WidgetConfiguration {
        var id: UUID
        var event: KueEvent?
        var widgetType: WidgetType
        var showLocation: Bool
        var isEnabled: Bool

        init(
            id: UUID = UUID(),
            event: KueEvent? = nil,
            widgetType: WidgetType,
            showLocation: Bool = true,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.event = event
            self.widgetType = widgetType
            self.showLocation = showLocation
            self.isEnabled = isEnabled
        }
    }

    /// Exact copy of `Shared/Models/WidgetState.swift` as it stood before Kue 2.0 Phase 4 — see
    /// file header (event points at the nested sibling).
    @Model
    final class WidgetState {
        var id: UUID
        var event: KueEvent?
        var currentPhase: WidgetLifecyclePhase
        var headline: String
        var subline: String?
        var progress: Double?
        var nextTransitionDate: Date

        init(
            id: UUID = UUID(),
            event: KueEvent? = nil,
            currentPhase: WidgetLifecyclePhase,
            headline: String,
            subline: String? = nil,
            progress: Double? = nil,
            nextTransitionDate: Date
        ) {
            self.id = id
            self.event = event
            self.currentPhase = currentPhase
            self.headline = headline
            self.subline = subline
            self.progress = progress
            self.nextTransitionDate = nextTransitionDate
        }
    }

    /// Exact copy of `Shared/Models/KueEvent.swift` as it stood before Kue 2.0 Phase 4 — see
    /// file header. Never edit this nested type again either; it is now the permanent V2.0
    /// snapshot. Relationships point at the nested `KueTask`/`KueSchedule`/
    /// `WidgetConfiguration`/`WidgetState` siblings above, not the live ones.
    @Model
    final class KueEvent {
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
        var recurrence: RecurrenceRule?
        var schemaVersion: Int
        var seriesID: UUID?
        var recurrenceAnchorDate: Date?
        var isRecurrenceException: Bool = false
        var isSkipped: Bool = false
        var skippedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \KueTask.event)
        var tasks: [KueTask]

        @Relationship(deleteRule: .cascade, inverse: \KueSchedule.event)
        var schedule: KueSchedule?

        @Relationship(deleteRule: .cascade, inverse: \WidgetConfiguration.event)
        var widgetConfiguration: WidgetConfiguration?

        @Relationship(deleteRule: .cascade, inverse: \WidgetState.event)
        var widgetState: WidgetState?

        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            title: String,
            eventType: EventType,
            startDate: Date,
            endDate: Date? = nil,
            estimatedDurationMinutes: Int,
            isAllDay: Bool = false,
            timeZoneIdentifier: String = TimeZone.current.identifier,
            location: String? = nil,
            notes: String? = nil,
            source: EventSource,
            priority: Priority = .medium,
            status: EventStatus = .upcoming,
            isCancelled: Bool = false,
            cancelledAt: Date? = nil,
            isManuallyCompleted: Bool = false,
            manuallyCompletedAt: Date? = nil,
            recurrence: RecurrenceRule? = nil,
            schemaVersion: Int = 1,
            seriesID: UUID? = nil,
            recurrenceAnchorDate: Date? = nil,
            isRecurrenceException: Bool = false,
            isSkipped: Bool = false,
            skippedAt: Date? = nil,
            tasks: [KueTask] = [],
            schedule: KueSchedule? = nil,
            widgetConfiguration: WidgetConfiguration? = nil,
            widgetState: WidgetState? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.eventType = eventType
            self.startDate = startDate
            self.endDate = endDate
            self.estimatedDurationMinutes = estimatedDurationMinutes
            self.isAllDay = isAllDay
            self.timeZoneIdentifier = timeZoneIdentifier
            self.location = location
            self.notes = notes
            self.source = source
            self.priority = priority
            self.status = status
            self.isCancelled = isCancelled
            self.cancelledAt = cancelledAt
            self.isManuallyCompleted = isManuallyCompleted
            self.manuallyCompletedAt = manuallyCompletedAt
            self.recurrence = recurrence
            self.schemaVersion = schemaVersion
            self.seriesID = seriesID
            self.recurrenceAnchorDate = recurrenceAnchorDate
            self.isRecurrenceException = isRecurrenceException
            self.isSkipped = isSkipped
            self.skippedAt = skippedAt
            self.tasks = tasks
            self.schedule = schedule
            self.widgetConfiguration = widgetConfiguration
            self.widgetState = widgetState
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
