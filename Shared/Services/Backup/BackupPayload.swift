//
//  BackupPayload.swift
//  Kue
//
//  Kue 2.0 Phase 12 — docs/28. The versioned, checksummed on-disk backup format. Deliberately
//  layered on top of Phase 11's own sync payload types (`EventSyncRecord`,
//  `RecurrenceExclusionSyncRecord`, `EventGraphMapper`) rather than a parallel encoding: a
//  backup and a CloudKit sync record solve the identical problem — "this event's whole local
//  graph, as a plain Codable value" — and `EventSyncRecord`'s own tolerant, future-version-safe
//  decode (docs/26 "O.") is exactly what a backup restored on a newer/older Kue build also
//  needs. `Template`/`UserPreference` have no sync record (Phase 11 never synced them), so they
//  get small dedicated payloads here.
//
//  **What's included**: every `KueEvent` (with tasks/schedule/widget configuration),
//  `RecurrenceExclusion`, `Template`, and the `UserPreference` singleton — everything that
//  represents a deliberate user choice.
//  **What's excluded, deliberately**: `WidgetState` (purely derived/denormalized, regenerated
//  by `EventReconciliation` after restore — docs/03 "WidgetState"); every `externalCalendar*`
//  field on `KueEvent` (device-local EKEvent linkage, no cross-device/cross-install identity
//  guarantee, same reasoning as docs/26 "D." for sync); `SyncPreference`/`ReminderPreference`/
//  `LiveActivityPrivacyPreference`/`SpotlightIndexingPreference` and the CloudKit sync engine's
//  own outbox/state (App-Group `UserDefaults`-backed device settings, not user *content*, and
//  restoring them onto a different device/install would be surprising, not helpful).
//

import Foundation
import CryptoKit

nonisolated enum BackupFormat {
    /// Kue 3.0 Phase 3 — docs/31 "Backup and restore": bumped from 1 to export/import
    /// `NotificationRule` rows. `BackupPayload.notificationRules` decodes tolerantly (defaults
    /// to `[]` when the key is absent), so a version-1 backup — which never had this field at
    /// all — still imports cleanly with every event/task falling back to its global-default
    /// notification behavior, exactly as `KueSchemaV4`'s own migration already guarantees for
    /// an in-place upgrade. See `BackupCoder.decodeAndValidate`'s existing
    /// `unsupportedFutureFormatVersion` guard for the other direction: a version-2-or-newer
    /// backup restored on an older build already fails closed, unchanged by this bump.
    static let currentVersion = 2
    /// The file extension Export/Restore UX (Section E/F) reads and writes —
    /// `docs/27-personal-device-installation.md` documents this for a user restoring by hand.
    static let fileExtension = "kuebackup"
}

nonisolated enum BackupError: Error, Equatable {
    /// The file isn't valid JSON, or doesn't match `BackupEnvelope`'s own shape at all —
    /// not a Kue backup file (or too corrupted to even recognize as an attempt at one).
    case notABackupFile
    /// `BackupEnvelope.checksum` doesn't match a fresh SHA-256 of `BackupEnvelope.payload` —
    /// the file was truncated, edited, or corrupted in transit. Never proceed to decode the
    /// payload, let alone touch SwiftData, when this fires.
    case checksumMismatch
    /// `BackupEnvelope.formatVersion` is newer than `BackupFormat.currentVersion` — this
    /// backup was made by a newer version of Kue than is installed. Never guess at an unknown
    /// container shape.
    case unsupportedFutureFormatVersion(found: Int, maxSupported: Int)
    /// The envelope and checksum are valid, but `payload` itself doesn't decode as
    /// `BackupPayload` (a corruption checksum alone can't catch, or a genuinely malformed
    /// payload despite a technically-matching hash).
    case malformedPayload
}

/// Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults". Deliberately
/// leaner than `NotificationRulePayload`: no `eventID`/`taskID` (a template default has no
/// owner, by construction), no `absoluteDate` (structurally excluded — see
/// `NotificationRuleDefault.swift`'s own header), no `sortOrder`/`createdAt`/`updatedAt` (a
/// plain value array on `Template`, not a separately-identified, timestamped row).
nonisolated struct NotificationRuleDefaultPayload: Codable, Equatable {
    var id: UUID
    var anchor: String
    var offsetDirection: String
    var offsetQuantity: Int
    var offsetUnit: String
    var isEnabled: Bool
    var customTitle: String?
    var customBody: String?
    var sound: String
    var interruptionPreference: String
    var snoozeMinutes: Int?
}

/// Reuses `ScheduleRulePayload`/`RecurrenceRulePayload` etc. from EventSyncRecord.swift —
/// see this file's header for why.
///
/// `notificationRuleDefaults` decodes tolerantly to `[]` for any backup written before this
/// phase's completion pass — same "old field genuinely absent, not merely empty" policy
/// `BackupPayload.notificationRules` already established for `NotificationRule` itself.
nonisolated struct TemplateBackupPayload: Codable, Equatable {
    var id: UUID
    var name: String
    /// Raw value of `EventType`. Unrecognized future case falls back to `.generic`, same
    /// policy as every other raw-value field in this format.
    var eventType: String
    var scheduleRules: [ScheduleRulePayload]
    var isUserDefined: Bool
    var isBuiltIn: Bool
    var notificationRuleDefaults: [NotificationRuleDefaultPayload]

    init(
        id: UUID, name: String, eventType: String, scheduleRules: [ScheduleRulePayload],
        isUserDefined: Bool, isBuiltIn: Bool, notificationRuleDefaults: [NotificationRuleDefaultPayload] = []
    ) {
        self.id = id
        self.name = name
        self.eventType = eventType
        self.scheduleRules = scheduleRules
        self.isUserDefined = isUserDefined
        self.isBuiltIn = isBuiltIn
        self.notificationRuleDefaults = notificationRuleDefaults
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, eventType, scheduleRules, isUserDefined, isBuiltIn, notificationRuleDefaults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        eventType = try container.decode(String.self, forKey: .eventType)
        scheduleRules = try container.decode([ScheduleRulePayload].self, forKey: .scheduleRules)
        isUserDefined = try container.decode(Bool.self, forKey: .isUserDefined)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        notificationRuleDefaults = try container.decodeIfPresent([NotificationRuleDefaultPayload].self, forKey: .notificationRuleDefaults) ?? []
    }
}

nonisolated struct UserPreferenceBackupPayload: Codable, Equatable {
    /// Raw value of `NotificationIntensity`. Unrecognized future case falls back to `.standard`.
    var notificationIntensity: String
    var aiParsingEnabled: Bool
}

/// Kue 3.0 Phase 3 — docs/31 "Backup and restore". Raw-value fields fall back to a safe default
/// on an unrecognized future case, same policy as every other raw-value field in this format;
/// `BackupRestoreService` additionally runs every decoded row through
/// `NotificationRuleValidator` before it ever touches SwiftData (docs/31: "Reject invalid
/// anchors, offsets, and enum values safely").
nonisolated struct NotificationRulePayload: Codable, Equatable {
    var id: UUID
    /// Exactly one of `eventID`/`taskID` is expected — mirrors `NotificationRule.event`/`.task`.
    var eventID: UUID?
    var taskID: UUID?
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

/// The actual content — what `BackupEnvelope.payload`'s bytes decode to, once the envelope's
/// checksum/version have already been validated. `notificationRules` decodes tolerantly to `[]`
/// for a version-1 backup (which predates this field entirely) — see `BackupFormat
/// .currentVersion`'s own header.
nonisolated struct BackupPayload: Codable, Equatable {
    var events: [EventSyncRecord]
    var exclusions: [RecurrenceExclusionSyncRecord]
    var templates: [TemplateBackupPayload]
    var userPreference: UserPreferenceBackupPayload?
    var notificationRules: [NotificationRulePayload]

    init(
        events: [EventSyncRecord], exclusions: [RecurrenceExclusionSyncRecord], templates: [TemplateBackupPayload],
        userPreference: UserPreferenceBackupPayload?, notificationRules: [NotificationRulePayload] = []
    ) {
        self.events = events
        self.exclusions = exclusions
        self.templates = templates
        self.userPreference = userPreference
        self.notificationRules = notificationRules
    }

    private enum CodingKeys: String, CodingKey {
        case events, exclusions, templates, userPreference, notificationRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([EventSyncRecord].self, forKey: .events)
        exclusions = try container.decode([RecurrenceExclusionSyncRecord].self, forKey: .exclusions)
        templates = try container.decode([TemplateBackupPayload].self, forKey: .templates)
        userPreference = try container.decodeIfPresent(UserPreferenceBackupPayload.self, forKey: .userPreference)
        notificationRules = try container.decodeIfPresent([NotificationRulePayload].self, forKey: .notificationRules) ?? []
    }
}

/// The on-disk container. `payload` is opaque `Data` (a nested JSON-encoded `BackupPayload`),
/// not a directly-nested `Codable` struct — so `checksum` verifies the exact bytes about to be
/// decoded, not a re-encoding of them (re-encoding could plausibly differ in key order/float
/// formatting and produce false corruption positives or, worse, false negatives).
nonisolated struct BackupEnvelope: Codable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    /// Informational only (shown in Restore's preview UI) — never used for any decode/safety
    /// decision, which is entirely `formatVersion`'s job.
    var exportedByAppVersion: String
    var checksum: String
    var payload: Data

    init(formatVersion: Int = BackupFormat.currentVersion, exportedAt: Date, exportedByAppVersion: String, payload: Data) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.exportedByAppVersion = exportedByAppVersion
        self.payload = payload
        self.checksum = Self.checksum(for: payload)
    }

    static func checksum(for payload: Data) -> String {
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    /// The one encoder configuration every backup-format encode uses — `BackupCoder` and
    /// tests that need to hand-construct an envelope both go through this rather than
    /// restating `.iso8601` separately.
    nonisolated static var kueBackupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var kueBackupDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
