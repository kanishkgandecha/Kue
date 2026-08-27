//
//  KueSchemaV1.swift
//  Kue
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation. See docs/15-schema-migrations.md for the
//  full policy this file exists to satisfy.
//
//  `KueSchemaV1` is the *exact, currently-shipped* V1.0 model shape — every real App-Group
//  store already on a user's device was written against this shape — frozen here verbatim as
//  a `VersionedSchema` so it can be named as the starting point of a `SchemaMigrationPlan`.
//
//  Kue 2.0 Phase 3 update (docs/17-recurring-events.md "Migration"): until now, "the V1 shape"
//  and "the current shape" were the same types, so `models` below could reference the live
//  `Shared/Models/` types directly. Phase 3 is the first change that actually changes
//  `KueEvent`'s stored shape (new recurrence-related fields — see `KueSchemaV2.swift`), which
//  means the live `KueEvent` symbol now means the *new* shape. Leaving `models` pointing at it
//  would silently redefine what "opening a v1.0 store" means — exactly the failure mode this
//  file exists to prevent — so `KueEvent` is nested here as `KueSchemaV1.KueEvent`: a
//  byte-for-byte copy of the class exactly as it stood immediately before Phase 3.
//
//  This is the one instance where editing this file's *content* is required to keep it
//  representing what it always represented — not a change to what V1.0 actually shipped with.
//
//  A subtlety discovered empirically (not just theoretically) while building this: it is
//  **not enough** to nest only the type that actually changed shape (`KueEvent`). SwiftData
//  requires every `@Model` type reachable from it via a `@Relationship` to also be part of the
//  same self-consistent schema graph — `KueTask`/`KueSchedule`/`WidgetConfiguration`/
//  `WidgetState` all hold `var event: KueEvent?`, and the *live* versions of those four types
//  point that property at the *live* (V2-shaped) `KueEvent`. Building a schema from
//  `[KueSchemaV1.KueEvent.self, KueTask.self, ...]` (mixing the nested V1 event with the live,
//  V2-pointing children) crashed at runtime — `Fatal error: Expected only Arrays for
//  Relationships` — the first attempt at this file only nested `KueEvent` and hit exactly that.
//  The fix: every type with a relationship *to* the changed type must be nested too, each
//  pointing at its nested siblings, so the whole connected subgraph is internally consistent.
//  `Template` and `UserPreference` have no relationship to `KueEvent` — they're untouched
//  islands in the graph — so they still reference the live, shared types directly, per
//  docs/15-schema-migrations.md step 2's "only types that actually changed [or are connected to
//  a changed type] need a new, version-suffixed type."
//
//  PRODUCTION INCIDENT (2026-08-27) — corrected here: the paragraph above (and the original
//  version of this file) assumed `KueEvent.recurrence` was already part of V1.0 — "reserved,
//  always nil" — and so carried a `var recurrence: RecurrenceRule?` into this nested snapshot
//  type. That assumption was never actually verified against a real V1.0 store, and it was
//  wrong: opening a genuine pre-migration App Group store (`NSStoreModelVersionIdentifiers ==
//  ["1.0.0"]`) failed with NSCocoaErrorDomain 134504, "Cannot use staged migration with an
//  unknown model version." Direct inspection of that store's SQLite schema
//  (`ZKUEEVENT`'s column list) proved its `KueEvent` entity has **no `ZRECURRENCE` column at
//  all** — every other attribute, relationship, and entity across all seven modeled types
//  matched this file exactly (cross-checked column-by-column against `Z_PRIMARYKEY`/
//  `.schema`), so `recurrence` being present here was the one and only discrepancy producing
//  the version-hash mismatch. `recurrence` is genuinely new as of `KueSchemaV2` (see that
//  file's header) — removed from this type below, and backfilled explicitly by
//  `KueMigrationPlan.migrateV1toV2`, exactly like the five other Phase-3 fields already were.
//  `KueTests/Migrations/RealV1SchemaRegressionTests.swift` pins this entity's exact property
//  set going forward so this can't silently regress again.
//
//  `versionIdentifier = Schema.Version(1, 0, 0)` is not an arbitrary choice: it's SwiftData's
//  own default (`Schema.init(_:version:)`'s `version` parameter defaults to `Version(1, 0,
//  0)`), which is exactly what every real V1.0 store already has encoded in its metadata,
//  since `ModelContainerFactory.schema` was originally built via that same defaulted
//  initializer, before this migration foundation existed. Matching it here — rather than
//  picking a fresh `Version(1, 0, 0)`-looking-but-different identifier — is what lets
//  SwiftData recognize an existing store as already being this schema, not something needing
//  (or worse, unable to find) a migration path.
//

import SwiftData
import Foundation

enum KueSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            KueEvent.self,
            KueTask.self,
            KueSchedule.self,
            WidgetConfiguration.self,
            WidgetState.self,
            Template.self,
            UserPreference.self,
        ]
    }

    /// Exact copy of `Shared/Models/KueTask.swift` as it stood before Kue 2.0 Phase 3, except
    /// `event` now points at the nested `KueSchemaV1.KueEvent` sibling instead of the live one
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

    /// Exact copy of `Shared/Models/KueSchedule.swift` as it stood before Kue 2.0 Phase 3 — see
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
    /// Phase 3 — see file header (event points at the nested sibling).
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

    /// Exact copy of `Shared/Models/WidgetState.swift` as it stood before Kue 2.0 Phase 3 — see
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

    /// Exact copy of `Shared/Models/KueEvent.swift` as it stood before Kue 2.0 Phase 3 — see
    /// file header. Never edit this nested type again either; it is now the permanent V1.0
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
        var schemaVersion: Int

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
            schemaVersion: Int = 1,
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
            self.schemaVersion = schemaVersion
            self.tasks = tasks
            self.schedule = schedule
            self.widgetConfiguration = widgetConfiguration
            self.widgetState = widgetState
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
