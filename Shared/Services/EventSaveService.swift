//
//  EventSaveService.swift
//  Kue
//
//  Kue 3.0 Phase 1 (macOS Foundation, docs/29) — extracted out of `EventFormView.save()`
//  (Kue/Features/EventForm/, iOS-only) so the new native Mac editor doesn't duplicate this
//  same ~80-line "validate is already done by the caller; dispatch add vs. plain-edit vs.
//  recurring-scoped-edit; persist; mark the sync outbox; reload the widget; cancel stale
//  notifications" orchestration — the exact same reasoning `EventCreationService.create` was
//  already extracted from this same function for in Kue 2.0 Phase 10 ("App Intents must never
//  duplicate mutation business logic"), just one layer further out. `EventFormView.swift`
//  itself was refactored to call this too, so iOS and Mac now share one save path byte-for-
//  byte — behavior preserved exactly, not reimplemented.
//
//  Deliberately excludes: validation (the caller runs `EventValidator.validate`/
//  `validateRecurrence` first and only calls this once both are empty, matching
//  `EventFormView.save()`'s own existing contract), the async post-write reconciliation
//  (`EventCreationService.reconcileAfterWrite` — fire-and-forget from UI, awaited from
//  callers that need a truthful result before reporting success), and anything UI-specific
//  (haptics, dismissal, `Task` scheduling) — those stay the caller's job on each platform.
//

import Foundation
import SwiftData

enum EventSaveMode {
    case add(source: EventSource)
    /// `editScope` is only consulted when `event.seriesID != nil` — an editable single event
    /// ignores it entirely, matching `EventFormView`'s own existing behavior (the scope picker
    /// only ever appears for a series occurrence).
    case edit(event: KueEvent, editScope: RecurrenceEditScope)
}

/// Everything a caller needs after a synchronous save to run the shared async reconciliation
/// and clean up stale notification identifiers — mirrors exactly what `EventFormView.save()`
/// used to do with its own local `createdEvent`/`staleIdentifiers` variables.
struct EventSaveResult {
    let event: KueEvent
    let staleNotificationIdentifiers: [String]
}

enum EventSaveService {
    @discardableResult
    static func save(draft: EventDraft, mode: EventSaveMode, context: ModelContext, now: Date = .now) -> EventSaveResult {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var staleIdentifiers: [String] = []
        let event: KueEvent

        switch mode {
        case .add(let source):
            // Kue 2.0 Phase 10 — shared with App Intents (`EventCreationService.swift`), so
            // Siri/Shortcuts/Mac-created events go through the identical construction sequence.
            event = EventCreationService.create(from: draft, source: source, context: context, now: now)

        case .edit(let existing, let editScope):
            if existing.seriesID != nil {
                // Kue 2.0 Phase 3 — route through the This Occurrence / This and Future split.
                let outcome = OccurrenceReconciliationService.applyEdit(
                    scope: editScope, to: existing, values: draft, context: context, now: now
                )
                staleIdentifiers = outcome.staleNotificationIdentifiers
            } else {
                existing.title = title
                existing.eventType = draft.eventType
                existing.startDate = draft.startDate
                existing.endDate = draft.eventType == .trip ? draft.endDate : nil
                existing.isAllDay = draft.isAllDay
                existing.location = draft.location.isEmpty ? nil : draft.location
                existing.notes = draft.notes.isEmpty ? nil : draft.notes
                existing.priority = draft.priority
                existing.timeZoneIdentifier = draft.timeZoneIdentifier
                existing.updatedAt = now
                EventStatusEngine.reconcile(existing, now: now)
                staleIdentifiers = NotificationCandidateBuilder.allIdentifiers(for: existing)
                // Regenerates from event.schedule.rules per docs/05-scheduling-engine.md
                // "Editing an event after its schedule is generated" — safe to call
                // unconditionally since it's a no-op for anything a completed task already covers.
                SchedulingEngine.regenerateTasks(for: existing, context: context, now: now)
                // A plain event can start a fresh series from an edit too.
                startSeriesIfNeeded(for: existing, draft: draft, context: context, now: now)
            }
            event = existing
        }

        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": covers both the add and plain-edit paths —
        // `OccurrenceReconciliationService.applyEdit` marks any *additional* occurrences it
        // touches itself; this covers the primary `event`.
        SyncOutbox.markEventDirty(event.id)
        // docs/07-widget-engine.md "Refresh strategy" — a placed widget won't otherwise
        // notice this write until its own precomputed timeline next reloads.
        EventActions.reloadWidget()
        if !staleIdentifiers.isEmpty {
            SystemNotificationScheduler.shared.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }

        return EventSaveResult(event: event, staleNotificationIdentifiers: staleIdentifiers)
    }

    private static func startSeriesIfNeeded(for event: KueEvent, draft: EventDraft, context: ModelContext, now: Date) {
        guard let rule = draft.recurrenceRule else { return }
        event.recurrence = rule
        event.seriesID = UUID()
        event.recurrenceAnchorDate = event.startDate
        OccurrenceReconciliationService.materializeInitialOccurrences(from: event, context: context, now: now)
    }
}
