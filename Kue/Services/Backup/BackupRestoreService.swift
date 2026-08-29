//
//  BackupRestoreService.swift
//  Kue
//
//  Kue 2.0 Phase 12 — docs/28. Applies an already-validated `BackupPayload` (see
//  `BackupCoder.decodeAndValidate` — checksum/version already checked, never called with raw
//  file bytes) into a `ModelContext`. Merge-by-UUID only, never a destructive "replace
//  everything" — the spec's own bar for that ("an automatic verified pre-restore backup,
//  explicit destructive confirmation, fully validated input, transactional/recoverable
//  application, rollback on any failure") isn't something a plain SwiftData `context.save()`
//  can prove, so this ships merge-only, same as the spec's own fallback instruction.
//
//  Reuses Phase 11's own conflict policy (`SyncConflictResolver`) rather than inventing a
//  second one: a backup file's event and "what CloudKit's zone currently says" solve the exact
//  same problem — reconcile one incoming version of an event's whole graph against whatever
//  this device currently has, same last-writer-wins-by-`updatedAt` + deterministic tie-break
//  rule either way. This mirrors `SyncCoordinator.applyRemoteChanges`'s own loop structure.
//

import Foundation
import SwiftData

nonisolated struct BackupRestoreSummary: Equatable {
    var eventsInserted = 0
    var eventsUpdated = 0
    var eventsSkippedAsOlder = 0
    var exclusionsInserted = 0
    var templatesInserted = 0
    var preferenceRestored = false
}

nonisolated enum BackupRestoreService {
    /// Applies every part of `payload` to `context` and saves once at the end — SwiftData's
    /// `ModelContext.save()` is itself transactional (docs/13-error-handling.md precedent used
    /// throughout this codebase), so a failure here throws before anything is committed rather
    /// than leaving a half-applied store.
    @MainActor
    static func restore(payload: BackupPayload, context: ModelContext, now: Date = Date()) async throws -> BackupRestoreSummary {
        var summary = BackupRestoreSummary()

        for record in payload.events {
            let existing = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == record.id })))?.first
            let localState: SyncConflictResolver.LocalState = existing.map { .record(EventGraphMapper.record(for: $0)) } ?? .absent
            switch SyncConflictResolver.resolve(local: localState, remote: .record(record)) {
            case .applyRemote:
                if let existing {
                    let orphaned = EventGraphMapper.apply(record, to: existing)
                    for task in orphaned { context.delete(task) }
                    summary.eventsUpdated += 1
                } else {
                    context.insert(EventGraphMapper.makeEvent(from: record))
                    summary.eventsInserted += 1
                }
            case .keepLocal:
                summary.eventsSkippedAsOlder += 1
            case .deleteLocal, .restoreLocal:
                break // unreachable here — a backup record is never a tombstone
            }
        }

        for record in payload.exclusions {
            let existing = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>(predicate: #Predicate { $0.id == record.id })))?.first
            guard existing == nil else { continue } // create-only, same policy as sync
            context.insert(EventGraphMapper.makeExclusion(from: record))
            summary.exclusionsInserted += 1
        }

        for record in payload.templates {
            let existing = (try? context.fetch(FetchDescriptor<Template>(predicate: #Predicate { $0.id == record.id })))?.first
            guard existing == nil else { continue } // never overwrite an existing template, built-in or otherwise
            context.insert(BackupCoder.makeTemplate(from: record))
            summary.templatesInserted += 1
        }

        if let preference = payload.userPreference {
            let local = UserPreferenceStore.current(context: context)
            local.notificationIntensity = NotificationIntensity(rawValue: preference.notificationIntensity) ?? .standard
            local.aiParsingEnabled = preference.aiParsingEnabled
            summary.preferenceRestored = true
        }

        try context.save()

        // docs/26 "B./Q." precedent (`SyncCoordinator.applyRemoteChanges`) — any restored
        // event needs the same bounded reconciliation pass every other mutation surface
        // triggers, so status/occurrence horizon/widget/Spotlight reflect the newly-restored
        // data immediately rather than waiting for the next unrelated trigger.
        if summary.eventsInserted > 0 || summary.eventsUpdated > 0 {
            await EventReconciliation.run(context: context, now: now)
        }

        return summary
    }
}
