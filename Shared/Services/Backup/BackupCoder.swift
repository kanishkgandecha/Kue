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

        return BackupPayload(
            events: events.map(EventGraphMapper.record(for:)),
            exclusions: exclusions.map(EventGraphMapper.record(for:)),
            templates: templates.map(templatePayload),
            userPreference: preference.map {
                UserPreferenceBackupPayload(notificationIntensity: $0.notificationIntensity.rawValue, aiParsingEnabled: $0.aiParsingEnabled)
            }
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
            isBuiltIn: template.isBuiltIn
        )
    }

    static func makeTemplate(from payload: TemplateBackupPayload) -> Template {
        Template(
            id: payload.id,
            name: payload.name,
            eventType: EventType(rawValue: payload.eventType) ?? .generic,
            scheduleRules: payload.scheduleRules.map { ScheduleRule(offset: $0.offset, taskTitle: $0.taskTitle, isTimeSensitive: $0.isTimeSensitive) },
            isUserDefined: payload.isUserDefined,
            isBuiltIn: payload.isBuiltIn
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
