//
//  EventSyncRecord.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "C." The one synced payload for an
//  event's whole local graph (`KueEvent` + its `KueTask`s + `KueSchedule` +
//  `WidgetConfiguration`) — see `SyncRecordFormat`'s own header for why these travel together
//  as one CloudKit record rather than four separately-referenced ones. Pure `Codable` value
//  types, no SwiftData/CloudKit import — `CloudRecordCoding` (Kue/Services/Sync/, app-only)
//  is the only place this crosses into an actual `CKRecord`, and `EventGraphMapper`
//  (Shared/Services/Sync/) is the only place it crosses into/out of `KueEvent`/`KueTask`/
//  `KueSchedule`/`WidgetConfiguration` themselves.
//
//  docs/26 "D." — deliberately excludes every `externalCalendar*` field: an `EKEvent`
//  identifier or Calendar identifier valid on one device has no guaranteed meaning on another
//  (Apple gives no cross-device identity guarantee for them), so Calendar linkage stays
//  device-local. `source == .calendarImport` itself *is* synced — "this event was imported
//  from Calendar" is a fact about the event's origin, independent of which specific EKEvent
//  produced it.
//

import Foundation

/// Thrown by tolerant decoding when a payload's own stamped format version is newer than this
/// build understands — docs/26 "O.": "rejection/quarantine of unsupported future versions,"
/// never a partial or best-effort decode of a shape this build wasn't written for.
enum SyncDecodingError: Error, Equatable {
    case unsupportedFutureVersion(found: Int, maxSupported: Int)
}

nonisolated struct TaskSyncPayload: Codable, Equatable {
    var id: UUID
    var title: String
    var dueDate: Date
    var isCompleted: Bool
    var completedAt: Date?
    var offsetLabel: String
    var sortOrder: Int
}

nonisolated struct ScheduleRulePayload: Codable, Equatable {
    /// `DateComponents` itself is already `Codable` — stored as-is, same as
    /// `KueSchedule.rulesData`'s own local JSON encoding.
    var offset: DateComponents
    var taskTitle: String
    var isTimeSensitive: Bool
}

nonisolated struct SchedulePayload: Codable, Equatable {
    var id: UUID
    /// Raw value of `ScheduleTemplateType`. Kue 2.0 Phase 11 — docs/26 "O." enum fallback
    /// policy: an unrecognized future case (a newer Kue build introduced one this build
    /// doesn't know) decodes to `.custom` on read, never throws — `.custom` is the one case
    /// that already means "don't assume a known built-in shape."
    var templateType: String
    var rules: [ScheduleRulePayload]
    var isCustom: Bool
    var generatedAt: Date
}

nonisolated struct WidgetConfigurationPayload: Codable, Equatable {
    var id: UUID
    /// Raw value of `WidgetType`. Unrecognized future case falls back to `.countdown` (the
    /// simplest, always-valid rendering) rather than failing the whole event's decode.
    var widgetType: String
    var showLocation: Bool
    var isEnabled: Bool
}

/// Kue 3.0 Phase 5 — docs/33 "Synchronized scope." One `NotificationRule`, event- or
/// task-owned within *this* event's own graph — `taskID` is `nil` for an event-owned rule, or
/// one of this event's own `tasks[].id` for a task-owned one (mirrors the local model's own
/// "exactly one of event/task" invariant). Travels embedded here rather than as its own synced
/// entity, exactly like `TaskSyncPayload` already does — it has no independent identity apart
/// from the event graph it belongs to, and a rule add/edit is pushed by re-sending the whole
/// event graph (`SyncOutbox.markNotificationRulesDirty`), never a separate sync record. Its
/// *deletion*, unlike an edit, does get an explicit tombstone (requirement I) — see
/// `SyncOutbox.markNotificationRuleDeleted`/`SyncPushBatch.notificationRuleDeletions` — so a
/// rule's absence from this array is corroborated by that explicit signal, not the sole proof
/// of deletion.
nonisolated struct NotificationRuleSyncPayload: Codable, Equatable {
    var id: UUID
    var taskID: UUID?
    /// Raw value of `NotificationRuleAnchor`. Unrecognized future case falls back to
    /// `.eventStart` (never crashes the whole event's decode over one unknown rule anchor).
    var anchor: String
    var offsetDirection: String
    var offsetQuantity: Int
    var offsetUnit: String
    var absoluteDate: Date?
    var isEnabled: Bool
    var customTitle: String?
    var customBody: String?
    var sound: String
    var interruptionPreference: String
    var snoozeMinutes: Int?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct RecurrenceRulePayload: Codable, Equatable {
    /// Raw value of `RecurrenceRule.Frequency`.
    var frequency: String
    var interval: Int
    /// Mirrors `RecurrenceRule.End` — encoded as an explicit kind tag rather than relying on
    /// `Codable`'s default enum-with-associated-value encoding, so a future case this build
    /// doesn't recognize can fall back to `.never` instead of failing the decode entirely.
    var endKind: String
    var endDate: Date?
    var endOccurrenceCount: Int?
}

/// docs/26 "C.": the one CloudKit record type for an event's whole synced graph.
nonisolated struct EventSyncRecord: Codable, Equatable {
    var recordFormatVersion: Int
    var id: UUID
    var title: String
    /// Raw value of `EventType`. Unrecognized future case falls back to `.generic`.
    var eventType: String
    var startDate: Date
    var endDate: Date?
    var estimatedDurationMinutes: Int
    var isAllDay: Bool
    var timeZoneIdentifier: String
    var location: String?
    var notes: String?
    /// Raw value of `EventSource`. Unrecognized future case falls back to `.manual`.
    var source: String
    /// Raw value of `Priority`. Unrecognized future case falls back to `.medium`.
    var priority: String
    var isCancelled: Bool
    var cancelledAt: Date?
    var isManuallyCompleted: Bool
    var manuallyCompletedAt: Date?
    var recurrence: RecurrenceRulePayload?
    var seriesID: UUID?
    var recurrenceAnchorDate: Date?
    var isRecurrenceException: Bool
    var isSkipped: Bool
    var skippedAt: Date?
    var tasks: [TaskSyncPayload]
    var schedule: SchedulePayload?
    var widgetConfiguration: WidgetConfigurationPayload?
    /// Kue 3.0 Phase 5 — see `NotificationRuleSyncPayload`'s own header.
    var notificationRules: [NotificationRuleSyncPayload]
    var createdAt: Date
    /// The whole-graph conflict-resolution timestamp for a *local* record (this device's own
    /// `KueEvent.updatedAt`, bumped by every `EventActions`/`WidgetIntentActions` explicit
    /// mutation). For a record decoded from a *pull* response, `SupabaseSyncTransport` stamps
    /// this with the server's own `server_updated_at` instead — never a remote device's local
    /// clock — before `SyncConflictResolver` ever sees it (docs/33 "Conflict policy": "do not
    /// trust client clocks as the conflict authority").
    var updatedAt: Date
    /// Kue 3.0 Phase 5 — the server-assigned revision this record was fetched at (0 for a
    /// purely local, never-yet-pushed record). Sent back as `expectedRevision` on this event's
    /// next push for optimistic-concurrency conflict detection — see `SyncPushResult
    /// .conflictedEventIDs`.
    var revision: Int64
    /// This device's own idempotency key for the *specific* mutation this push represents — a
    /// retried push of the identical local state reuses the same value, so the server can
    /// recognize a duplicate delivery even where content alone wouldn't prove it.
    var clientMutationID: UUID

    init(
        recordFormatVersion: Int = SyncRecordFormat.currentEventFormatVersion,
        id: UUID, title: String, eventType: String, startDate: Date, endDate: Date?,
        estimatedDurationMinutes: Int, isAllDay: Bool, timeZoneIdentifier: String,
        location: String?, notes: String?, source: String, priority: String,
        isCancelled: Bool, cancelledAt: Date?, isManuallyCompleted: Bool, manuallyCompletedAt: Date?,
        recurrence: RecurrenceRulePayload?, seriesID: UUID?, recurrenceAnchorDate: Date?,
        isRecurrenceException: Bool, isSkipped: Bool, skippedAt: Date?,
        tasks: [TaskSyncPayload], schedule: SchedulePayload?, widgetConfiguration: WidgetConfigurationPayload?,
        notificationRules: [NotificationRuleSyncPayload] = [],
        createdAt: Date, updatedAt: Date, revision: Int64 = 0, clientMutationID: UUID = UUID()
    ) {
        self.recordFormatVersion = recordFormatVersion
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
        self.isCancelled = isCancelled
        self.cancelledAt = cancelledAt
        self.isManuallyCompleted = isManuallyCompleted
        self.manuallyCompletedAt = manuallyCompletedAt
        self.recurrence = recurrence
        self.seriesID = seriesID
        self.recurrenceAnchorDate = recurrenceAnchorDate
        self.isRecurrenceException = isRecurrenceException
        self.isSkipped = isSkipped
        self.skippedAt = skippedAt
        self.tasks = tasks
        self.schedule = schedule
        self.widgetConfiguration = widgetConfiguration
        self.notificationRules = notificationRules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.clientMutationID = clientMutationID
    }

    private enum CodingKeys: String, CodingKey {
        case recordFormatVersion, id, title, eventType, startDate, endDate,
             estimatedDurationMinutes, isAllDay, timeZoneIdentifier, location, notes,
             source, priority, isCancelled, cancelledAt, isManuallyCompleted, manuallyCompletedAt,
             recurrence, seriesID, recurrenceAnchorDate, isRecurrenceException, isSkipped, skippedAt,
             tasks, schedule, widgetConfiguration, notificationRules, createdAt, updatedAt,
             revision, clientMutationID
    }

    /// Tolerant decode — docs/26 "O.": missing optional fields fall back to safe defaults,
    /// and a payload stamped with a newer format version than this build supports throws
    /// `SyncDecodingError.unsupportedFutureVersion` immediately (before any partial field is
    /// even trusted) so the caller quarantines the whole record rather than half-applying it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .recordFormatVersion) ?? 1
        guard version <= SyncRecordFormat.currentEventFormatVersion else {
            throw SyncDecodingError.unsupportedFutureVersion(found: version, maxSupported: SyncRecordFormat.currentEventFormatVersion)
        }
        recordFormatVersion = version
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? "generic"
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        estimatedDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedDurationMinutes) ?? 0
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        isCancelled = try container.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        cancelledAt = try container.decodeIfPresent(Date.self, forKey: .cancelledAt)
        isManuallyCompleted = try container.decodeIfPresent(Bool.self, forKey: .isManuallyCompleted) ?? false
        manuallyCompletedAt = try container.decodeIfPresent(Date.self, forKey: .manuallyCompletedAt)
        recurrence = try container.decodeIfPresent(RecurrenceRulePayload.self, forKey: .recurrence)
        seriesID = try container.decodeIfPresent(UUID.self, forKey: .seriesID)
        recurrenceAnchorDate = try container.decodeIfPresent(Date.self, forKey: .recurrenceAnchorDate)
        isRecurrenceException = try container.decodeIfPresent(Bool.self, forKey: .isRecurrenceException) ?? false
        isSkipped = try container.decodeIfPresent(Bool.self, forKey: .isSkipped) ?? false
        skippedAt = try container.decodeIfPresent(Date.self, forKey: .skippedAt)
        tasks = try container.decodeIfPresent([TaskSyncPayload].self, forKey: .tasks) ?? []
        schedule = try container.decodeIfPresent(SchedulePayload.self, forKey: .schedule)
        widgetConfiguration = try container.decodeIfPresent(WidgetConfigurationPayload.self, forKey: .widgetConfiguration)
        notificationRules = try container.decodeIfPresent([NotificationRuleSyncPayload].self, forKey: .notificationRules) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? startDate
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startDate
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        clientMutationID = try container.decodeIfPresent(UUID.self, forKey: .clientMutationID) ?? UUID()
    }
}

/// docs/26 "C.": `RecurrenceExclusion` has no owning event UUID (keyed by `seriesID` +
/// `excludedAnchorDate`), so it travels as its own small record type.
nonisolated struct RecurrenceExclusionSyncRecord: Codable, Equatable {
    var recordFormatVersion: Int
    var id: UUID
    var seriesID: UUID
    var excludedAnchorDate: Date
    var clientMutationID: UUID

    init(recordFormatVersion: Int = SyncRecordFormat.currentRecurrenceExclusionFormatVersion, id: UUID, seriesID: UUID, excludedAnchorDate: Date, clientMutationID: UUID = UUID()) {
        self.recordFormatVersion = recordFormatVersion
        self.id = id
        self.seriesID = seriesID
        self.excludedAnchorDate = excludedAnchorDate
        self.clientMutationID = clientMutationID
    }

    private enum CodingKeys: String, CodingKey {
        case recordFormatVersion, id, seriesID, excludedAnchorDate, clientMutationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .recordFormatVersion) ?? 1
        guard version <= SyncRecordFormat.currentRecurrenceExclusionFormatVersion else {
            throw SyncDecodingError.unsupportedFutureVersion(found: version, maxSupported: SyncRecordFormat.currentRecurrenceExclusionFormatVersion)
        }
        recordFormatVersion = version
        id = try container.decode(UUID.self, forKey: .id)
        seriesID = try container.decode(UUID.self, forKey: .seriesID)
        excludedAnchorDate = try container.decode(Date.self, forKey: .excludedAnchorDate)
        clientMutationID = try container.decodeIfPresent(UUID.self, forKey: .clientMutationID) ?? UUID()
    }
}
