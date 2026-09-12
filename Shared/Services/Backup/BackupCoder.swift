//
//  BackupCoder.swift
//  Kue
//
//  Kue 2.0 Phase 12 — docs/28. Export (SwiftData → `BackupEnvelope` bytes) and the validate-
//  before-decode restore path (bytes → checked `BackupPayload`). `decodeAndValidate` is
//  deliberately the *only* way into a `BackupPayload` from untrusted file bytes: it checks the
//  checksum and format version before ever asking `JSONDecoder` to build a single
//  `EventSyncRecord`/`KueEvent`, so a corrupted or hand-edited file is rejected before anything
//  resembling a SwiftData object exists (see BackupPayload.swift's own header for why this
//  matters — "do not deserialize directly into SwiftData models before validation").
//

import Foundation
import SwiftData

nonisolated enum BackupCoder {
    // MARK: - Export

    static func exportPayload(context: ModelContext) throws -> BackupPayload {
        let events = try context.fetch(FetchDescriptor<KueEvent>())
        let exclusions = try context.fetch(FetchDescriptor<RecurrenceExclusion>())
        let templates = try context.fetch(FetchDescriptor<Template>())
        let preference = try context.fetch(FetchDescriptor<UserPreference>()).first
        let notificationRules = try context.fetch(FetchDescriptor<NotificationRule>())

        return BackupPayload(
            // Kue 3.0 Phase 5 — `EventGraphMapper.record(for:)` now also embeds an event's
            // notification rules (for sync push), but `.kuebackup` already has its own,
            // separate, independently-tested top-level `notificationRules` backup mechanism
            // below — cleared here so a restore's event-processing loop (which reuses this
            // same `EventGraphMapper.apply`/`makeEvent`) never double-creates a rule already
            // handled by that dedicated path.
            events: events.map { event in
                var record = EventGraphMapper.record(for: event)
                record.notificationRules = []
                return record
            },
            exclusions: exclusions.map(EventGraphMapper.record(for:)),
            templates: templates.map(templatePayload),
            userPreference: preference.map {
                UserPreferenceBackupPayload(notificationIntensity: $0.notificationIntensity.rawValue, aiParsingEnabled: $0.aiParsingEnabled)
            },
            notificationRules: notificationRules.map(notificationRulePayload)
        )
    }

    static func makeEnvelope(payload: BackupPayload, exportedAt: Date, appVersion: String) throws -> BackupEnvelope {
        let payloadData = try JSONEncoder.kueBackupEncoder.encode(payload)
        return BackupEnvelope(exportedAt: exportedAt, exportedByAppVersion: appVersion, payload: payloadData)
    }

    /// The one function `ExportBackupService` (Section E) calls — fetch, wrap, serialize to the
    /// bytes that get written to a `.kuebackup` file.
    static func exportData(context: ModelContext, exportedAt: Date = Date(), appVersion: String? = nil) throws -> Data {
        let payload = try exportPayload(context: context)
        let envelope = try makeEnvelope(
            payload: payload,
            exportedAt: exportedAt,
            appVersion: appVersion ?? Bundle.main.appVersionForBackup
        )
        let encoder = JSONEncoder.kueBackupEncoder
        encoder.outputFormatting = [.sortedKeys] // stable, human-diffable if someone ever opens it
        return try encoder.encode(envelope)
    }

    // MARK: - Validate-before-decode restore path

    /// Decodes and fully validates a `.kuebackup` file's bytes — checksum and format version
    /// checked before `payload` is ever handed to `JSONDecoder`. Never touches `ModelContext`;
    /// applying a validated `BackupPayload` is `BackupRestoreService`'s job (Section F/G), kept
    /// as a separate step so a caller can show the user a preview (event/task counts,
    /// `exportedAt`) before committing to anything.
    static func decodeAndValidate(_ data: Data) throws -> (envelope: BackupEnvelope, payload: BackupPayload) {
        let decoder = JSONDecoder.kueBackupDecoder
        guard let envelope = try? decoder.decode(BackupEnvelope.self, from: data) else {
            throw BackupError.notABackupFile
        }
        guard envelope.formatVersion <= BackupFormat.currentVersion else {
            throw BackupError.unsupportedFutureFormatVersion(found: envelope.formatVersion, maxSupported: BackupFormat.currentVersion)
        }
        guard BackupEnvelope.checksum(for: envelope.payload) == envelope.checksum else {
            throw BackupError.checksumMismatch
        }
        guard let payload = try? decoder.decode(BackupPayload.self, from: envelope.payload) else {
            throw BackupError.malformedPayload
        }
        return (envelope, payload)
    }

    // MARK: - Template mapping (no sync record precedent — small and local to this file)

    private static func templatePayload(_ template: Template) -> TemplateBackupPayload {
        TemplateBackupPayload(
            id: template.id,
            name: template.name,
            eventType: template.eventType.rawValue,
            scheduleRules: template.scheduleRules.map { ScheduleRulePayload(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) },
            isUserDefined: template.isUserDefined,
            isBuiltIn: template.isBuiltIn,
            notificationRuleDefaults: template.notificationRuleDefaults.map(notificationRuleDefaultPayload)
        )
    }

    static func makeTemplate(from payload: TemplateBackupPayload) -> Template {
        Template(
            id: payload.id,
            name: payload.name,
            eventType: EventType(rawValue: payload.eventType) ?? .generic,
            scheduleRules: payload.scheduleRules.map { ScheduleRule(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) },
            notificationRuleDefaults: payload.notificationRuleDefaults.map(makeNotificationRuleDefault),
            isUserDefined: payload.isUserDefined,
            isBuiltIn: payload.isBuiltIn
        )
    }

    private static func notificationRuleDefaultPayload(_ ruleDefault: NotificationRuleDefault) -> NotificationRuleDefaultPayload {
        NotificationRuleDefaultPayload(
            id: ruleDefault.id, anchor: ruleDefault.anchor.rawValue, offsetDirection: ruleDefault.offsetDirection.rawValue,
            offsetQuantity: ruleDefault.offsetQuantity, offsetUnit: ruleDefault.offsetUnit.rawValue,
            isEnabled: ruleDefault.isEnabled, customTitle: ruleDefault.customTitle, customBody: ruleDefault.customBody,
            sound: ruleDefault.sound.rawValue, interruptionPreference: ruleDefault.interruptionPreference.rawValue,
            snoozeMinutes: ruleDefault.snoozeMinutes
        )
    }

    /// Unrecognized raw values fall back to a safe default, same policy as every other mapper
    /// in this file. `BackupRestoreService` separately runs `NotificationRuleDefault.validate()`
    /// on the result before ever assigning it onto a `Template`.
    static func makeNotificationRuleDefault(from payload: NotificationRuleDefaultPayload) -> NotificationRuleDefault {
        NotificationRuleDefault(
            id: payload.id,
            anchor: TemplateNotificationAnchor(rawValue: payload.anchor) ?? .eventStart,
            offsetDirection: NotificationOffsetDirection(rawValue: payload.offsetDirection) ?? .at,
            offsetQuantity: payload.offsetQuantity,
            offsetUnit: NotificationOffsetUnit(rawValue: payload.offsetUnit) ?? .minutes,
            isEnabled: payload.isEnabled,
            customTitle: payload.customTitle,
            customBody: payload.customBody,
            sound: NotificationSoundOption(rawValue: payload.sound) ?? .defaultSound,
            interruptionPreference: NotificationInterruptionPreference(rawValue: payload.interruptionPreference) ?? .active,
            snoozeMinutes: payload.snoozeMinutes
        )
    }

    // MARK: - NotificationRule mapping (Kue 3.0 Phase 3 — docs/31 "Backup and restore")

    private static func notificationRulePayload(_ rule: NotificationRule) -> NotificationRulePayload {
        NotificationRulePayload(
            id: rule.id, eventID: rule.event?.id, taskID: rule.task?.id,
            anchor: rule.anchor.rawValue, offsetDirection: rule.offsetDirection.rawValue,
            offsetQuantity: rule.offsetQuantity, offsetUnit: rule.offsetUnit.rawValue,
            absoluteDate: rule.absoluteDate, isEnabled: rule.isEnabled,
            customTitle: rule.customTitle, customBody: rule.customBody,
            sound: rule.sound.rawValue, interruptionPreference: rule.interruptionPreference.rawValue,
            snoozeMinutes: rule.snoozeMinutes, sortOrder: rule.sortOrder,
            createdAt: rule.createdAt, updatedAt: rule.updatedAt
        )
    }

    /// `event`/`task` are the caller's already-resolved owners (looked up by
    /// `payload.eventID`/`payload.taskID`) — this function never fetches, matching every other
    /// `make*(from:)` mapper in this file. Unrecognized raw values fall back to a safe default,
    /// same policy as `makeTemplate(from:)` above; `BackupRestoreService` separately runs
    /// `NotificationRuleValidator` on the *result* before ever inserting it.
    static func makeNotificationRule(from payload: NotificationRulePayload, event: KueEvent?, task: KueTask?) -> NotificationRule {
        NotificationRule(
            id: payload.id, event: event, task: task,
            anchor: NotificationRuleAnchor(rawValue: payload.anchor) ?? .absolute,
            offsetDirection: NotificationOffsetDirection(rawValue: payload.offsetDirection) ?? .at,
            offsetQuantity: payload.offsetQuantity,
            offsetUnit: NotificationOffsetUnit(rawValue: payload.offsetUnit) ?? .minutes,
            absoluteDate: payload.absoluteDate, isEnabled: payload.isEnabled,
            customTitle: payload.customTitle, customBody: payload.customBody,
            sound: NotificationSoundOption(rawValue: payload.sound) ?? .defaultSound,
            interruptionPreference: NotificationInterruptionPreference(rawValue: payload.interruptionPreference) ?? .active,
            snoozeMinutes: payload.snoozeMinutes, sortOrder: payload.sortOrder,
            createdAt: payload.createdAt, updatedAt: payload.updatedAt
        )
    }
}

extension Bundle {
    /// `CFBundleShortVersionString` (e.g. "2.0") — informational only, stamped into the
    /// envelope for a human reading a Restore preview, never read back to decide anything.
    nonisolated var appVersionForBackup: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }
}
