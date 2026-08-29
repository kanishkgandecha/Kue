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
    static let currentVersion = 1
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

/// Reuses `ScheduleRulePayload`/`RecurrenceRulePayload` etc. from EventSyncRecord.swift —
/// see this file's header for why.
nonisolated struct TemplateBackupPayload: Codable, Equatable {
    var id: UUID
    var name: String
    /// Raw value of `EventType`. Unrecognized future case falls back to `.generic`, same
    /// policy as every other raw-value field in this format.
    var eventType: String
    var scheduleRules: [ScheduleRulePayload]
    var isUserDefined: Bool
    var isBuiltIn: Bool
}

nonisolated struct UserPreferenceBackupPayload: Codable, Equatable {
    /// Raw value of `NotificationIntensity`. Unrecognized future case falls back to `.standard`.
    var notificationIntensity: String
    var aiParsingEnabled: Bool
}

/// The actual content — what `BackupEnvelope.payload`'s bytes decode to, once the envelope's
/// checksum/version have already been validated.
nonisolated struct BackupPayload: Codable, Equatable {
    var events: [EventSyncRecord]
    var exclusions: [RecurrenceExclusionSyncRecord]
    var templates: [TemplateBackupPayload]
    var userPreference: UserPreferenceBackupPayload?
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
