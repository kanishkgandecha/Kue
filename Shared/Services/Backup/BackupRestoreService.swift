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
    var templateNotificationDefaultsRejected = 0
    var preferenceRestored = false
    var notificationRulesInserted = 0
    var notificationRulesUpdated = 0
    var notificationRulesRejected = 0
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
                    for task in orphaned.orphanedTasks { context.delete(task) }
                    for rule in orphaned.orphanedNotificationRules { context.delete(rule) }
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
            let template = BackupCoder.makeTemplate(from: record)
            // Kue 3.0 Phase 3 completion pass — reject an individually-invalid notification
            // default rather than the whole template, same "skip, don't fail closed on one bad
            // row" policy `NotificationRule` restore below already uses.
            let validDefaults = template.notificationRuleDefaults.filter { ruleDefault in
                (try? ruleDefault.validate()) != nil
            }
            summary.templateNotificationDefaultsRejected += template.notificationRuleDefaults.count - validDefaults.count
            template.notificationRuleDefaults = validDefaults
            context.insert(template)
            summary.templatesInserted += 1
        }

        if let preference = payload.userPreference {
            let local = UserPreferenceStore.current(context: context)
            local.notificationIntensity = NotificationIntensity(rawValue: preference.notificationIntensity) ?? .standard
            local.aiParsingEnabled = preference.aiParsingEnabled
            summary.preferenceRestored = true
        }

        // Kue 3.0 Phase 3 — docs/31 "Backup and restore": merge by stable UUID, preserve
        // existing event/task relationships, reject an invalid/orphaned row individually
        // rather than aborting the whole restore (the same "skip, don't fail closed on one bad
        // row" policy exclusions/templates above already use).
        for record in payload.notificationRules {
            guard record.eventID != nil || record.taskID != nil else {
                summary.notificationRulesRejected += 1
                continue // neither owner present — a corrupted/foreign row, never inserted
            }
            let event = record.eventID.flatMap { id in
                try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first
            }
            let task = record.taskID.flatMap { id in
                try? context.fetch(FetchDescriptor<KueTask>(predicate: #Predicate { $0.id == id })).first
            }
            // The owning event/task must exist in *this* store — a rule whose owner didn't
            // come along in the same restore (or was already deleted here) is rejected rather
            // than inserted as a dangling relationship.
            guard (record.eventID == nil || event != nil), (record.taskID == nil || task != nil) else {
                summary.notificationRulesRejected += 1
                continue
            }

            let candidate = BackupCoder.makeNotificationRule(from: record, event: event, task: task)
            do {
                try NotificationRuleValidator.validate(candidate)
            } catch {
                summary.notificationRulesRejected += 1
                continue
            }

            if let existing = try? context.fetch(FetchDescriptor<NotificationRule>(predicate: #Predicate { $0.id == record.id })).first {
                guard record.updatedAt > existing.updatedAt else { continue } // local wins a tie/newer-local, same last-writer-wins policy as events
                existing.event = event
                existing.task = task
                existing.anchor = candidate.anchor
                existing.offsetDirection = candidate.offsetDirection
                existing.offsetQuantity = candidate.offsetQuantity
                existing.offsetUnit = candidate.offsetUnit
                existing.absoluteDate = candidate.absoluteDate
                existing.isEnabled = candidate.isEnabled
                existing.customTitle = candidate.customTitle
                existing.customBody = candidate.customBody
                existing.sound = candidate.sound
                existing.interruptionPreference = candidate.interruptionPreference
                existing.snoozeMinutes = candidate.snoozeMinutes
                existing.sortOrder = candidate.sortOrder
                existing.updatedAt = candidate.updatedAt
                summary.notificationRulesUpdated += 1
            } else {
                context.insert(candidate)
                summary.notificationRulesInserted += 1
            }
        }

        try context.save()

        // docs/26 "B./Q." precedent (`SyncCoordinator.applyRemoteChanges`) — any restored
        // event needs the same bounded reconciliation pass every other mutation surface
        // triggers, so status/occurrence horizon/Spotlight reflect the newly-restored data
        // immediately rather than waiting for the next unrelated trigger.
        if summary.eventsInserted > 0 || summary.eventsUpdated > 0 {
            await EventReconciliation.run(context: context, now: now)
        }
        // Post-Phase-12 fix — `EventReconciliation.run` only reloads widgets itself when its
        // own status/occurrence sweep detects a change, which a restore that inserts/updates
        // rows without flipping any derived status would not trigger. A restore is its own
        // real reason to reload regardless (the Lock Screen selection's own selected event, or
        // any tracked event, could be exactly what a restore just brought back or changed).
        if summary.eventsInserted > 0 || summary.eventsUpdated > 0 || summary.exclusionsInserted > 0 {
            EventActions.reloadWidget()
        }

        return summary
    }
}
