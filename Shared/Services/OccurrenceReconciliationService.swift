//
//  OccurrenceReconciliationService.swift
//  Kue
//
//  Kue 2.0 Phase 3 — Recurring Events. See docs/17-recurring-events.md for the full contract
//  this file implements: bounded materialization, replenishment, and the This Occurrence /
//  This and Future Occurrences edit-and-delete split. The SwiftData-touching counterpart to
//  RecurrenceEngine.swift's pure date math (Shared/), same split SchedulingEngine/
//  EventStatusEngine already establish.
//
//  App-only (not Shared/) because `applyEdit` takes an `EventDraft` (Kue/Services/
//  EventValidator.swift, app-only) and because — like EventDuplicationService/EventActions —
//  nothing outside the app target ever creates or edits a recurring series: NL/Share-Sheet
//  input doesn't set recurrence (out of scope this phase, docs/17-recurring-events.md "What
//  this phase deliberately does not do"), and no widget-extension App Intent mutates a series.
//

import Foundation
import SwiftData

/// docs/17-recurring-events.md "Editing scope" — the two scopes editing and deletion share.
enum RecurrenceEditScope {
    case thisOccurrence
    case thisAndFuture
}

enum OccurrenceReconciliationService {
    // MARK: - Creation

    /// Called right after `firstOccurrence` (already inserted, with `seriesID`/`recurrence`/
    /// `recurrenceAnchorDate` set to itself) — materializes the rest of the initial horizon.
    /// Returns every newly created occurrence, not including `firstOccurrence` itself.
    @discardableResult
    static func materializeInitialOccurrences(from firstOccurrence: KueEvent, context: ModelContext, now: Date = .now) -> [KueEvent] {
        guard let rule = firstOccurrence.recurrence,
              let seriesID = firstOccurrence.seriesID,
              let anchor = firstOccurrence.recurrenceAnchorDate
        else { return [] }

        let horizonEnd = now.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        let anchors = RecurrenceEngine.nextAnchors(
            rule: rule,
            lastAnchor: anchor,
            occurrencesSoFar: 1,
            timeZoneIdentifier: firstOccurrence.timeZoneIdentifier,
            horizonEnd: horizonEnd,
            // The origin itself already counts toward the minimum floor — see
            // RecurrenceEngine.nextAnchors' own doc comment.
            existingFutureCount: anchor > now ? 1 : 0
        )

        let created = anchors.map { newAnchor in
            makeOccurrence(template: firstOccurrence, seriesID: seriesID, anchorDate: newAnchor, context: context, now: now)
        }
        try? context.save()
        return created
    }

    // MARK: - Replenishment (docs/17-recurring-events.md "Reconciliation wiring")

    /// Called from `EventReconciliation.run` alongside `EventStatusEngine.sweep` — the same
    /// foreground/background/app-launch entry point. Idempotent: running it twice with no time
    /// passed produces zero new rows, since every new anchor is computed strictly after the
    /// latest already-existing (materialized or excluded) one for its series.
    @discardableResult
    static func replenishAll(context: ModelContext, now: Date = .now) -> Bool {
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let exclusions = (try? context.fetch(FetchDescriptor<RecurrenceExclusion>())) ?? []
        let seriesIDs = Set(events.compactMap(\.seriesID))
        guard !seriesIDs.isEmpty else { return false }

        let horizonEnd = now.addingTimeInterval(Double(RecurrenceEngine.horizonWindowDays) * 86_400)
        var changed = false

        for seriesID in seriesIDs {
            let members = events.filter { $0.seriesID == seriesID }
            let memberAnchors = members.compactMap(\.recurrenceAnchorDate)
            guard let rule = members.first(where: { $0.recurrence != nil })?.recurrence,
                  let maxAnchor = memberAnchors.max()
            else { continue }

            let excludedAnchors = Set(exclusions.filter { $0.seriesID == seriesID }.map(\.excludedAnchorDate))
            let occurrencesSoFar = memberAnchors.count + excludedAnchors.count

            // Template: prefer a non-exception member (so a prior "This and Future" split's
            // own field values keep winning) with the latest anchor; fall back to any member
            // if every one has been individually edited.
            let template = members.filter { !$0.isRecurrenceException }
                .max { ($0.recurrenceAnchorDate ?? .distantPast) < ($1.recurrenceAnchorDate ?? .distantPast) }
                ?? members.max { ($0.recurrenceAnchorDate ?? .distantPast) < ($1.recurrenceAnchorDate ?? .distantPast) }
            guard let template else { continue }

            let existingFutureCount = memberAnchors.filter { $0 > now }.count
            let newAnchors = RecurrenceEngine.nextAnchors(
                rule: rule,
                lastAnchor: maxAnchor,
                occurrencesSoFar: occurrencesSoFar,
                timeZoneIdentifier: template.timeZoneIdentifier,
                horizonEnd: horizonEnd,
                existingFutureCount: existingFutureCount
            ).filter { !excludedAnchors.contains($0) }

            for newAnchor in newAnchors {
                _ = makeOccurrence(template: template, seriesID: seriesID, anchorDate: newAnchor, context: context, now: now)
                changed = true
            }
        }

        if changed { try? context.save() }
        return changed
    }

    // MARK: - Editing

    struct EditOutcome {
        var staleNotificationIdentifiers: [String]
        var affectedOccurrences: [KueEvent]
    }

    /// Applies `values` (an already-validated `EventDraft`) to `occurrence` under `scope` — see
    /// docs/17-recurring-events.md "Editing scope" for the full contract. Callers (EventFormView)
    /// still own removing `staleNotificationIdentifiers` and triggering
    /// `NotificationEngine.reschedule`/`EventActions.reloadWidget()` afterward, mirroring the
    /// existing plain-edit path's own sequencing.
    static func applyEdit(scope: RecurrenceEditScope, to occurrence: KueEvent, values: EventDraft, context: ModelContext, now: Date = .now) -> EditOutcome {
        switch scope {
        case .thisOccurrence:
            return applyThisOccurrenceEdit(to: occurrence, values: values, context: context, now: now)
        case .thisAndFuture:
            return applyThisAndFutureEdit(to: occurrence, values: values, context: context, now: now)
        }
    }

    /// docs/17-recurring-events.md "This Occurrence" — mutate this one row in place, mark it an
    /// exception. `recurrenceAnchorDate`/`seriesID`/`recurrence` are left untouched: the slot
    /// still belongs to the series' anchor sequence, it's just no longer regenerable content.
    private static func applyThisOccurrenceEdit(to occurrence: KueEvent, values: EventDraft, context: ModelContext, now: Date) -> EditOutcome {
        let staleIdentifiers = NotificationCandidateBuilder.allIdentifiers(for: occurrence)
        applyEditableFields(values, to: occurrence, now: now)
        occurrence.isRecurrenceException = true
        EventStatusEngine.reconcile(occurrence, now: now)
        SchedulingEngine.regenerateTasks(for: occurrence, context: context, now: now)
        SyncOutbox.markEventDirty(occurrence.id) // Kue 2.0 Phase 11 — docs/26 "E."
        return EditOutcome(staleNotificationIdentifiers: staleIdentifiers, affectedOccurrences: [occurrence])
    }

    /// docs/17-recurring-events.md "This and Future Occurrences" — the deterministic split.
    private static func applyThisAndFutureEdit(to occurrence: KueEvent, values: EventDraft, context: ModelContext, now: Date) -> EditOutcome {
        guard let seriesID = occurrence.seriesID,
              let anchor = occurrence.recurrenceAnchorDate,
              let currentRule = occurrence.recurrence
        else {
            // Not actually part of a series — callers only offer this scope when seriesID !=
            // nil, but fall back safely to a plain single-occurrence edit rather than crash.
            return applyThisOccurrenceEdit(to: occurrence, values: values, context: context, now: now)
        }
        let newRule = values.recurrenceRule ?? currentRule

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let seriesMembers = allEvents.filter { $0.seriesID == seriesID }
        let priorMembers = seriesMembers.filter { ($0.recurrenceAnchorDate ?? .distantFuture) < anchor }
        let futureNonExceptionMembers = seriesMembers.filter {
            $0.id != occurrence.id && ($0.recurrenceAnchorDate ?? .distantPast) >= anchor && !$0.isRecurrenceException
        }
        let futureExceptionMembers = seriesMembers.filter {
            $0.id != occurrence.id && ($0.recurrenceAnchorDate ?? .distantPast) >= anchor && $0.isRecurrenceException
        }

        var staleIdentifiers: [String] = []
        var affected: [KueEvent] = []

        // No prior occurrence at all — nothing to split; the whole series becomes "the
        // future." No new seriesID is minted for a no-op split.
        let newSeriesID = priorMembers.isEmpty ? seriesID : UUID()

        if !priorMembers.isEmpty, let lastPriorAnchor = priorMembers.compactMap(\.recurrenceAnchorDate).max() {
            let truncatedRule = RecurrenceRule(frequency: currentRule.frequency, interval: currentRule.interval, end: .onDate(lastPriorAnchor))
            for prior in priorMembers { prior.recurrence = truncatedRule }
        }

        // Every non-exception future occurrence is about to be regenerated fresh under the new
        // template/rule — delete and re-plan rather than reconcile field-by-field.
        for member in futureNonExceptionMembers {
            // SwiftUI can still be rendering one of these materialized siblings behind the
            // edit sheet. Resolve its stored values before deletion so SwiftData does not
            // detach an unresolved fault that the existing view hierarchy may read while it
            // processes the save. Without this, editing "This and Future Occurrences" can
            // trap in BackingData.swift (most often at `eventType`) during dismissal.
            resolveStoredValuesBeforeDeletion(member)
            staleIdentifiers += NotificationCandidateBuilder.allIdentifiers(for: member)
            SyncOutbox.markEventDeleted(member.id, now: now) // Kue 2.0 Phase 11 — docs/26 "E."
            context.delete(member)
        }
        // Surviving exceptions keep their own field values untouched but reparent to the new
        // segment, so a later delete-this-and-future from the new head still reaches them.
        for exception in futureExceptionMembers {
            exception.seriesID = newSeriesID
            exception.recurrence = newRule
            SyncOutbox.markEventDirty(exception.id) // Kue 2.0 Phase 11 — docs/26 "E."
        }

        // The edited occurrence becomes the new segment's head.
        staleIdentifiers += NotificationCandidateBuilder.allIdentifiers(for: occurrence)
        applyEditableFields(values, to: occurrence, now: now)
        occurrence.seriesID = newSeriesID
        occurrence.recurrence = newRule
        occurrence.recurrenceAnchorDate = occurrence.startDate
        occurrence.isRecurrenceException = false
        EventStatusEngine.reconcile(occurrence, now: now)
        SchedulingEngine.regenerateTasks(for: occurrence, context: context, now: now)
        affected.append(occurrence)

        affected += materializeInitialOccurrences(from: occurrence, context: context, now: now)
        // Kue 2.0 Phase 11 — docs/26 "E.": every occurrence this edit touched or created —
        // the new head, reparented exceptions, and freshly materialized future occurrences.
        for event in affected { SyncOutbox.markEventDirty(event.id) }

        return EditOutcome(staleNotificationIdentifiers: staleIdentifiers, affectedOccurrences: affected)
    }

    /// SwiftData invalidates a deleted model's backing data on save. Views that were already
    /// handed that model may finish one final render during navigation dismissal, so every
    /// stored value they can legitimately display must be faulted in before the row is
    /// detached. Keep this list aligned with `KueEvent`'s persisted properties.
    private static func resolveStoredValuesBeforeDeletion(_ event: KueEvent) {
        _ = event.id
        _ = event.title
        _ = event.eventType
        _ = event.startDate
        _ = event.endDate
        _ = event.estimatedDurationMinutes
        _ = event.isAllDay
        _ = event.timeZoneIdentifier
        _ = event.location
        _ = event.notes
        _ = event.source
        _ = event.priority
        _ = event.status
        _ = event.isCancelled
        _ = event.cancelledAt
        _ = event.isManuallyCompleted
        _ = event.manuallyCompletedAt
        _ = event.recurrence
        _ = event.schemaVersion
        _ = event.seriesID
        _ = event.recurrenceAnchorDate
        _ = event.isRecurrenceException
        _ = event.isSkipped
        _ = event.skippedAt
        _ = event.externalCalendarEventIdentifier
        _ = event.externalCalendarIdentifier
        _ = event.externalCalendarTitle
        _ = event.externalCalendarLastSyncedAt
        _ = event.externalCalendarLastKnownModifiedAt
        _ = event.tasks.count
        _ = event.schedule?.id
        _ = event.widgetConfiguration?.id
        _ = event.widgetState?.id
        _ = event.createdAt
        _ = event.updatedAt
    }

    private static func applyEditableFields(_ values: EventDraft, to occurrence: KueEvent, now: Date) {
        occurrence.title = values.title.trimmingCharacters(in: .whitespacesAndNewlines)
        occurrence.eventType = values.eventType
        occurrence.startDate = values.startDate
        occurrence.endDate = values.eventType == .trip ? values.endDate : nil
        occurrence.isAllDay = values.isAllDay
        occurrence.location = values.location.isEmpty ? nil : values.location
        occurrence.notes = values.notes.isEmpty ? nil : values.notes
        occurrence.priority = values.priority
        occurrence.timeZoneIdentifier = values.timeZoneIdentifier
        occurrence.updatedAt = now
    }

    // MARK: - Deletion (docs/17-recurring-events.md "Deleting one occurrence")

    static func deleteOccurrence(
        _ occurrence: KueEvent,
        scope: RecurrenceEditScope,
        context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared
    ) {
        guard let seriesID = occurrence.seriesID, let anchor = occurrence.recurrenceAnchorDate else {
            // Not part of a series — unchanged plain-delete behavior (already reconciles Live
            // Activity itself).
            EventActions.delete(occurrence, context: context, scheduler: scheduler, liveActivityManager: liveActivityManager)
            return
        }

        switch scope {
        case .thisOccurrence:
            let exclusion = RecurrenceExclusion(seriesID: seriesID, excludedAnchorDate: anchor)
            context.insert(exclusion)
            let identifiers = NotificationCandidateBuilder.allIdentifiers(for: occurrence)
            context.delete(occurrence)
            try? context.save()
            // Kue 2.0 Phase 11 — docs/26 "E./C.": the deleted occurrence tombstones; the new
            // exclusion (its own record type — docs/26 "C.") is what actually prevents
            // replenishment from recreating this slot on another device too.
            SyncOutbox.markEventDeleted(occurrence.id, now: .now)
            SyncOutbox.markExclusionDirty(exclusion.id)
            EventActions.reloadWidget()
            if !identifiers.isEmpty { scheduler.removePendingNotificationRequests(withIdentifiers: identifiers) }
            // A focused occurrence deleted individually (both this-occurrence and
            // this-and-future below delete rows directly, bypassing EventActions.delete's own
            // reconciliation call) still needs its Live Activity moved to `.unavailable`.
            Task { await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: .now) }

        case .thisAndFuture:
            let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
            let seriesMembers = allEvents.filter { $0.seriesID == seriesID }
            let priorMembers = seriesMembers.filter { ($0.recurrenceAnchorDate ?? .distantFuture) < anchor }
            let futureMembers = seriesMembers.filter { ($0.recurrenceAnchorDate ?? .distantPast) >= anchor }

            if !priorMembers.isEmpty, let lastPriorAnchor = priorMembers.compactMap(\.recurrenceAnchorDate).max(),
               let rule = priorMembers.first?.recurrence {
                let truncatedRule = RecurrenceRule(frequency: rule.frequency, interval: rule.interval, end: .onDate(lastPriorAnchor))
                for prior in priorMembers {
                    prior.recurrence = truncatedRule
                    SyncOutbox.markEventDirty(prior.id) // Kue 2.0 Phase 11 — docs/26 "E."
                }
            }

            var identifiers: [String] = []
            for member in futureMembers {
                identifiers += NotificationCandidateBuilder.allIdentifiers(for: member)
                if let memberAnchor = member.recurrenceAnchorDate {
                    let exclusion = RecurrenceExclusion(seriesID: seriesID, excludedAnchorDate: memberAnchor)
                    context.insert(exclusion)
                    SyncOutbox.markExclusionDirty(exclusion.id) // Kue 2.0 Phase 11 — docs/26 "E."
                }
                SyncOutbox.markEventDeleted(member.id, now: .now) // Kue 2.0 Phase 11 — docs/26 "E."
                context.delete(member)
            }
            try? context.save()
            EventActions.reloadWidget()
            if !identifiers.isEmpty { scheduler.removePendingNotificationRequests(withIdentifiers: identifiers) }
            Task { await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: .now) }
        }
    }

    // MARK: - Shared occurrence construction

    /// Builds and inserts one new occurrence copying `template`'s editable fields — the same
    /// creation sequence a manually created event goes through (schedule + tasks via
    /// `SchedulingEngine`, a default `WidgetConfiguration`), per requirement 17. A `.trip`
    /// template's `endDate` is carried forward as the same whole-day length from `startDate`
    /// (not a fixed elapsed-seconds offset), so a month-end/DST clamp on `startDate` can't
    /// desync the return date from the departure date.
    @discardableResult
    private static func makeOccurrence(template: KueEvent, seriesID: UUID, anchorDate: Date, context: ModelContext, now: Date) -> KueEvent {
        var newEndDate: Date?
        if let templateEnd = template.endDate {
            let calendar = RecurrenceEngine.calendar(timeZoneIdentifier: template.timeZoneIdentifier)
            let lengthDays = calendar.dateComponents([.day], from: template.startDate, to: templateEnd).day ?? 0
            newEndDate = calendar.date(byAdding: .day, value: lengthDays, to: anchorDate)
        }

        let occurrence = KueEvent(
            title: template.title,
            eventType: template.eventType,
            startDate: anchorDate,
            endDate: newEndDate,
            estimatedDurationMinutes: template.estimatedDurationMinutes,
            isAllDay: template.isAllDay,
            timeZoneIdentifier: template.timeZoneIdentifier,
            location: template.location,
            notes: template.notes,
            source: template.source,
            priority: template.priority,
            recurrence: template.recurrence,
            seriesID: seriesID,
            recurrenceAnchorDate: anchorDate,
            createdAt: now,
            updatedAt: now
        )
        context.insert(occurrence)
        EventStatusEngine.reconcile(occurrence, now: now)

        if let templateSchedule = template.schedule {
            let schedule = KueSchedule(
                event: occurrence,
                templateType: templateSchedule.templateType,
                rules: templateSchedule.rules,
                isCustom: templateSchedule.isCustom,
                generatedAt: now
            )
            context.insert(schedule)
            occurrence.schedule = schedule
        }

        let widgetConfiguration = WidgetConfiguration(
            event: occurrence,
            widgetType: template.widgetConfiguration?.widgetType ?? WidgetType.defaultType(for: occurrence.eventType),
            showLocation: template.widgetConfiguration?.showLocation ?? true,
            isEnabled: template.widgetConfiguration?.isEnabled ?? true
        )
        context.insert(widgetConfiguration)
        occurrence.widgetConfiguration = widgetConfiguration

        SchedulingEngine.regenerateTasks(for: occurrence, context: context, now: now)

        // Kue 3.0 Phase 3 — docs/31 "Recurring events": "Series-created occurrences inherit
        // intended rules." Copies the template's own *event*-level `NotificationRule` rows as
        // fresh, independent copies (new `id`s) — never the same row re-parented, so a later
        // "this occurrence only" edit to one occurrence's rules can never leak into another's.
        // Task-level rules aren't copied here: `SchedulingEngine.regenerateTasks` above already
        // creates entirely new `KueTask` rows with new ids for this occurrence, so there is no
        // template task-level rule that could correctly re-target one of them by identity.
        for templateRule in template.notificationRules {
            let copy = NotificationRule(
                event: occurrence, anchor: templateRule.anchor,
                offsetDirection: templateRule.offsetDirection, offsetQuantity: templateRule.offsetQuantity, offsetUnit: templateRule.offsetUnit,
                absoluteDate: nil, // an absolute rule is a one-time, occurrence-specific reminder — never propagated to a different occurrence's own date
                isEnabled: templateRule.isEnabled, customTitle: templateRule.customTitle, customBody: templateRule.customBody,
                sound: templateRule.sound, interruptionPreference: templateRule.interruptionPreference, snoozeMinutes: templateRule.snoozeMinutes,
                sortOrder: templateRule.sortOrder, createdAt: now, updatedAt: now
            )
            guard templateRule.anchor != .absolute else { continue } // see above — never copied
            context.insert(copy)
        }
        return occurrence
    }
}
