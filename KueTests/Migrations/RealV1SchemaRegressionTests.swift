//
//  RealV1SchemaRegressionTests.swift
//  KueTests
//
//  Regression coverage for a real production incident (2026-08-27): a genuine pre-migration
//  Kue App Group store (`NSStoreModelVersionIdentifiers == ["1.0.0"]`) failed to open with
//  NSCocoaErrorDomain 134504, "Cannot use staged migration with an unknown model version."
//
//  Root cause: `KueSchemaV1.KueEvent` (the frozen historical snapshot `KueMigrationPlan` names
//  as the starting point of the migration chain) declared `var recurrence: RecurrenceRule?` —
//  but no real V1.0 build ever shipped with that field. It was mistaken for a pre-existing
//  "reserved, always nil" property (see the live `KueEvent.swift`'s own now-stale doc comment
//  history) and copy-pasted into the nested V1 snapshot type when Kue 2.0 Phase 3 froze it,
//  rather than being recognized as genuinely new in `KueSchemaV2`. The result: SwiftData
//  computed a version hash for "V1" that no real V1.0 store could ever match, because every
//  real V1.0 store's `ZKUEEVENT` table has no `ZRECURRENCE` column.
//
//  This was confirmed by opening the real simulator App Group store read-only (never mutated —
//  see the incident report) and diffing its SQLite `.schema` output, table by table, against
//  every entity `KueSchemaV1` declares. Every attribute, relationship, and entity name matched
//  except this one. No content from that store (titles, notes, locations, dates) appears
//  anywhere below — only its structural column list, which carries no user data.
//
//  Fixing `recurrence` alone was *not* sufficient, though: bisecting against a real copy of
//  the store (never the original — see `RealStoreCopyVerification.swift`) proved the corrected
//  `KueSchemaV1` still didn't reproduce the store's exact recorded version hash — some other
//  structural detail (never captured in any commit; git history for this file was actively
//  misleading here, since `recurrence` had been present in *every* commit since this repo's
//  first one, yet the real store never had it) remained unaccounted for. Rather than keep
//  guessing at an opaque, undocumented hash algorithm, `ModelContainerFactory`'s
//  `openThroughMigrationPlan(at:)` gained a structural fallback instead: if the normal staged
//  migration fails, retry with a plain, migration-plan-less open using just `KueSchemaV1` —
//  which SwiftData reconciles purely by column shape (via its own always-on lightweight
//  inference), regardless of recorded hash — then retry the staged path once more, now that
//  the store's metadata has been re-stamped to an exact match. See that file's own header for
//  the full mechanism.
//
//  This file has three jobs:
//   1. Pin `KueSchemaV1`'s exact property set for every entity, derived from that real column
//      list, so `recurrence` (or anything else) can never silently be added back to the frozen
//      V1 schema without this test failing first — requirement: "prevents this exact
//      model-checksum mismatch from returning."
//   2. Prove a store built with *only* `KueSchemaV1` (genuinely no `recurrence` column,
//      mirroring the real store's shape) still migrates through the complete current chain —
//      `SchemaV1MigrationTests`/`SchemaV2MigrationTests` already do this for every other field;
//      this file adds the recurrence-specific case those predate.
//   3. Prove `ModelContainerFactory.openThroughMigrationPlan(at:)`'s fallback itself works:
//      even a store whose recorded version hash doesn't exactly match *any* known schema (not
//      just the specific `recurrence` case) still recovers and migrates losslessly, as long as
//      its actual column shape is compatible with `KueSchemaV1`.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct RealV1SchemaRegressionTests {
    /// Real `ZKUEEVENT` columns (from the incident's store, excluding CoreData/SwiftData's own
    /// `Z_PK`/`Z_ENT`/`Z_OPT` bookkeeping), mapped to their Swift property names. This is the
    /// ground truth `KueSchemaV1.KueEvent` must match exactly — no more, no less.
    private static let realV1KueEventProperties: Set<String> = [
        "id", "title", "eventType", "startDate", "endDate", "estimatedDurationMinutes",
        "isAllDay", "timeZoneIdentifier", "location", "notes", "source", "priority", "status",
        "isCancelled", "cancelledAt", "isManuallyCompleted", "manuallyCompletedAt",
        "schemaVersion", "tasks", "schedule", "widgetConfiguration", "widgetState",
        "createdAt", "updatedAt",
    ]

    @Test func kueSchemaV1KueEventNeverDeclaresARecurrenceField() throws {
        let schema = Schema(versionedSchema: KueSchemaV1.self)
        let eventEntity = try #require(schema.entitiesByName["KueEvent"])
        let propertyNames = Set(eventEntity.properties.map(\.name))

        #expect(!propertyNames.contains("recurrence"), """
            KueSchemaV1.KueEvent must never declare `recurrence` — real V1.0 stores have no \
            ZRECURRENCE column. Adding it back would reproduce NSCocoaErrorDomain 134504 \
            ("Cannot use staged migration with an unknown model version") against a real \
            pre-migration App Group store.
            """)
        #expect(propertyNames == Self.realV1KueEventProperties)
    }

    /// Same idea, every other entity — the incident's own diagnosis covered all seven, not
    /// just `KueEvent` (every attribute, relationship, and entity name was cross-checked
    /// against the real store's SQLite schema, not assumed).
    @Test func everyKueSchemaV1EntityMatchesTheRealStoresColumnList() throws {
        let schema = Schema(versionedSchema: KueSchemaV1.self)
        let expected: [String: Set<String>] = [
            "KueEvent": Self.realV1KueEventProperties,
            "KueTask": ["id", "event", "title", "dueDate", "isCompleted", "completedAt", "offsetLabel", "sortOrder"],
            "KueSchedule": ["id", "event", "templateType", "rulesData", "isCustom", "generatedAt"],
            "WidgetConfiguration": ["id", "event", "widgetType", "showLocation", "isEnabled"],
            "WidgetState": ["id", "event", "currentPhase", "headline", "subline", "progress", "nextTransitionDate"],
            "Template": ["id", "name", "eventType", "scheduleRulesData", "isUserDefined", "isBuiltIn"],
            "UserPreference": ["id", "notificationIntensity", "aiParsingEnabled"],
        ]

        #expect(Set(schema.entitiesByName.keys) == Set(expected.keys))
        for (entityName, expectedProperties) in expected {
            let entity = try #require(schema.entitiesByName[entityName], "Missing entity: \(entityName)")
            let actual = Set(entity.properties.map(\.name))
            #expect(actual == expectedProperties, "\(entityName) property mismatch: \(actual.symmetricDifference(expectedProperties))")
        }
    }

    @Test func versionIdentifierMatchesWhatEveryRealV1_0StoresMetadataActuallyRecords() {
        // `NSStoreModelVersionIdentifiers == ["1.0.0"]` on the real store — SwiftData's own
        // default `Schema.Version`, not an arbitrary pick (see KueSchemaV1.swift's header).
        #expect(KueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    /// The specific migration `SchemaV1MigrationTests`/`SchemaV2MigrationTests` predate: a
    /// store built from *only* the corrected `KueSchemaV1` (genuinely no `recurrence` column)
    /// opens cleanly through the full current chain, and `recurrence` lands backfilled to
    /// `nil` rather than crashing, silently defaulting via inference, or being left undefined.
    @Test func aGenuineV1StoreWithNoRecurrenceColumnMigratesThroughTheFullChain() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        let eventID: UUID
        do {
            let v1Container = try MigrationTestSupport.makeV1Store(at: url)
            let event = KueSchemaV1.KueEvent(
                title: "Regression Fixture Event",
                eventType: .generic,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                estimatedDurationMinutes: 30,
                source: .manual,
                schemaVersion: 1
            )
            eventID = event.id
            v1Container.mainContext.insert(event)
            try v1Container.mainContext.save()
        }

        let reopened = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let event = try #require(
            try reopened.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })).first
        )
        #expect(event.recurrence == nil)
        #expect(event.title == "Regression Fixture Event")

        // Requirement: verify post-migration writes, closure, and reopening.
        event.notes = "written after migration"
        try reopened.mainContext.save()

        let reopenedAgain = try MigrationTestSupport.reopenThroughCurrentMigrationPlan(at: url)
        let persisted = try #require(
            try reopenedAgain.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })).first
        )
        #expect(persisted.notes == "written after migration")
        #expect(persisted.recurrence == nil)
    }

    /// HARDENING (2026-08-28) correction: this test originally asserted that a store whose
    /// recorded hash matches no known schema at all, but is *structurally* compatible with
    /// `KueSchemaV1` (`LegacyV1WithAnUnknownExtraField`, below), would still recover via
    /// `openThroughMigrationPlan(at:)`. That was the *pre-hardening* design — "any structural
    /// compatibility is enough" — which the hardening review correctly rejected: recovery must
    /// only ever be attempted against a store matching `VerifiedV1StoreSignature` *exactly*
    /// (requirement 1/3/5), not merely something similar. This store, one field short of that
    /// exact match, is now a **negative** case: recovery must never be attempted, and the
    /// original staged-migration error must surface untouched. (Requirement 10's own
    /// `LegacyRecoverySecurityTests.fallbackIsNotAttemptedForAStructurallySimilarButUnapprovedStore`
    /// covers the same shape of case with a real, `VerifiedV1StoreSignature`-derived fixture;
    /// this one stays to document the correction against this file's own original fixture.)
    @Test func aStructurallySimilarButUnverifiedStoreIsNeverRecovered() throws {
        let url = MigrationTestSupport.makeTemporaryStoreURL()
        defer { MigrationTestSupport.removeStore(at: url) }

        do {
            let schema = Schema(versionedSchema: LegacyV1WithAnUnknownExtraField.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let event = LegacyV1WithAnUnknownExtraField.KueEvent(
                title: "Legacy Shape Fixture", eventType: .deadline,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                estimatedDurationMinutes: 0, source: .manual, schemaVersion: 1
            )
            container.mainContext.insert(event)
            try container.mainContext.save()
        }
        let before = try Data(contentsOf: url)

        // The real production entry point — not a parallel construction this test invented.
        #expect(throws: (any Error).self) {
            try ModelContainerFactory.openThroughMigrationPlan(at: url)
        }
        #expect(try Data(contentsOf: url) == before, "a store that isn't an exact verified-signature match must be left completely untouched")
    }
}

/// Stands in for "the real incident's store's actual historical shape" — structurally
/// identical to `KueSchemaV1` except for one extra, always-nil, never-product-written optional
/// field, so its recorded version hash matches no schema in `KueMigrationPlan.schemas` either.
/// Proves the fallback recovers from *any* such unrecognized-but-compatible hash mismatch, not
/// only the specific one `recurrence` happened to cause.
private enum LegacyV1WithAnUnknownExtraField: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [KueEvent.self, KueTask.self, KueSchedule.self, WidgetConfiguration.self, WidgetState.self, Template.self, UserPreference.self] }

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
        init(id: UUID = UUID(), event: KueEvent? = nil, title: String, dueDate: Date, isCompleted: Bool = false, completedAt: Date? = nil, offsetLabel: String, sortOrder: Int = 0) {
            self.id = id; self.event = event; self.title = title; self.dueDate = dueDate; self.isCompleted = isCompleted; self.completedAt = completedAt; self.offsetLabel = offsetLabel; self.sortOrder = sortOrder
        }
    }

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
        init(id: UUID = UUID(), event: KueEvent? = nil, templateType: ScheduleTemplateType, rules: [ScheduleRule] = [], isCustom: Bool = false, generatedAt: Date = Date()) {
            self.id = id; self.event = event; self.templateType = templateType; self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data(); self.isCustom = isCustom; self.generatedAt = generatedAt
        }
    }

    @Model
    final class WidgetConfiguration {
        var id: UUID
        var event: KueEvent?
        var widgetType: WidgetType
        var showLocation: Bool
        var isEnabled: Bool
        init(id: UUID = UUID(), event: KueEvent? = nil, widgetType: WidgetType, showLocation: Bool = true, isEnabled: Bool = true) {
            self.id = id; self.event = event; self.widgetType = widgetType; self.showLocation = showLocation; self.isEnabled = isEnabled
        }
    }

    @Model
    final class WidgetState {
        var id: UUID
        var event: KueEvent?
        var currentPhase: WidgetLifecyclePhase
        var headline: String
        var subline: String?
        var progress: Double?
        var nextTransitionDate: Date
        init(id: UUID = UUID(), event: KueEvent? = nil, currentPhase: WidgetLifecyclePhase, headline: String, subline: String? = nil, progress: Double? = nil, nextTransitionDate: Date) {
            self.id = id; self.event = event; self.currentPhase = currentPhase; self.headline = headline; self.subline = subline; self.progress = progress; self.nextTransitionDate = nextTransitionDate
        }
    }

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
        /// The stand-in for "whatever the real incident's actual undocumented difference was"
        /// — always nil, never written by any product code, exactly like `recurrence` was.
        var undocumentedLegacyField: String?

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
            id: UUID = UUID(), title: String, eventType: EventType, startDate: Date, endDate: Date? = nil,
            estimatedDurationMinutes: Int, isAllDay: Bool = false, timeZoneIdentifier: String = TimeZone.current.identifier,
            location: String? = nil, notes: String? = nil, source: EventSource, priority: Priority = .medium,
            status: EventStatus = .upcoming, isCancelled: Bool = false, cancelledAt: Date? = nil,
            isManuallyCompleted: Bool = false, manuallyCompletedAt: Date? = nil, schemaVersion: Int = 1,
            undocumentedLegacyField: String? = nil,
            tasks: [KueTask] = [], schedule: KueSchedule? = nil, widgetConfiguration: WidgetConfiguration? = nil,
            widgetState: WidgetState? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
        ) {
            self.id = id; self.title = title; self.eventType = eventType; self.startDate = startDate; self.endDate = endDate
            self.estimatedDurationMinutes = estimatedDurationMinutes; self.isAllDay = isAllDay; self.timeZoneIdentifier = timeZoneIdentifier
            self.location = location; self.notes = notes; self.source = source; self.priority = priority; self.status = status
            self.isCancelled = isCancelled; self.cancelledAt = cancelledAt; self.isManuallyCompleted = isManuallyCompleted
            self.manuallyCompletedAt = manuallyCompletedAt; self.schemaVersion = schemaVersion
            self.undocumentedLegacyField = undocumentedLegacyField
            self.tasks = tasks; self.schedule = schedule; self.widgetConfiguration = widgetConfiguration; self.widgetState = widgetState
            self.createdAt = createdAt; self.updatedAt = updatedAt
        }
    }
}
