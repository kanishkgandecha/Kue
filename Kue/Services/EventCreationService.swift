//
//  EventCreationService.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "A./I." — the shared "persist a
//  validated `EventDraft` as a brand-new `KueEvent`" path, extracted out of
//  `EventFormView.save()`'s `.add` case (Kue 2.0 Phase 1-9's own logic, unchanged behavior)
//  so App Intents can create events without duplicating it — requirement: "App Intents must
//  never duplicate mutation business logic." Callers are responsible for validating first
//  (`EventValidator.validate`/`validateRecurrence`, no unresolved `DraftAmbiguity`) — this
//  service does not re-validate, matching `EventFormView.save()`'s own existing contract.
//

import Foundation
import SwiftData

enum EventCreationService {
    /// The synchronous SwiftData write + widget reload — split from `reconcileAfterCreate`
    /// below so `EventFormView.save()` can keep its existing "dismiss instantly, reconcile
    /// notifications/Live Activity/Spotlight in the background" UX unchanged while still
    /// sharing this exact construction sequence.
    @discardableResult
    static func create(from draft: EventDraft, source: EventSource, context: ModelContext, now: Date = .now) -> KueEvent {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = KueEvent(
            title: title,
            eventType: draft.eventType,
            startDate: draft.startDate,
            endDate: draft.eventType == .trip ? draft.endDate : nil,
            estimatedDurationMinutes: draft.eventType.defaultEstimatedDurationMinutes,
            isAllDay: draft.isAllDay,
            location: draft.location.isEmpty ? nil : draft.location,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            source: source,
            priority: draft.priority,
            // Kue 2.0 Phase 4 — nil for every non-Calendar-import draft; set only when this
            // draft came from CalendarImportPipeline.
            externalCalendarEventIdentifier: draft.externalCalendarEventIdentifier,
            externalCalendarIdentifier: draft.externalCalendarIdentifier,
            externalCalendarTitle: draft.externalCalendarTitle,
            externalCalendarLastKnownModifiedAt: draft.externalCalendarLastKnownModifiedAt
        )
        EventStatusEngine.reconcile(event, now: now)
        context.insert(event)
        let widgetConfiguration = WidgetConfiguration(
            event: event,
            widgetType: WidgetType.defaultType(for: draft.eventType)
        )
        context.insert(widgetConfiguration)
        event.widgetConfiguration = widgetConfiguration
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        startSeriesIfNeeded(for: event, draft: draft, context: context, now: now)

        try? context.save()
        // Kue 2.0 Phase 11 — docs/26 "E.": the one shared creation path (`EventFormView`'s
        // `.add` case and every creation `AppIntent` all route through this function), so
        // marking here covers app UI, Siri/Shortcuts, and Control-driven creation uniformly —
        // never a per-call-site duplicate of this line.
        SyncOutbox.markEventDirty(event.id)
        EventActions.reloadWidget()

        return event
    }

    /// The shared post-write reconciliation both create and edit need — notification
    /// reschedule, Live Activity update, and (Phase 10) Spotlight indexing. Fire-and-forget
    /// from `EventFormView` (instant dismiss); awaited from App Intents, which should only
    /// report success once the write is genuinely consistent everywhere (requirement I:
    /// "return a truthful result").
    static func reconcileAfterWrite(
        _ event: KueEvent,
        context: ModelContext,
        now: Date = .now,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared,
        spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared
    ) async {
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(
            context: context, intensity: intensity, scheduler: scheduler, requestPermissionIfNeeded: true
        )
        await LiveActivityReconciler.reconcile(context: context, manager: liveActivityManager, now: now)
        await spotlightIndexer.index([SpotlightEventPayloadBuilder.payload(for: event, now: now)])
    }

    /// Kue 2.0 Phase 3 — turns `event` into the origin of a brand-new series when the draft's
    /// recurrence controls are on, and materializes the rest of the initial horizon. A no-op
    /// (`draft.recurrenceRule == nil`) for every non-recurring create.
    private static func startSeriesIfNeeded(for event: KueEvent, draft: EventDraft, context: ModelContext, now: Date) {
        guard let rule = draft.recurrenceRule else { return }
        event.recurrence = rule
        event.seriesID = UUID()
        event.recurrenceAnchorDate = event.startDate
        OccurrenceReconciliationService.materializeInitialOccurrences(from: event, context: context, now: now)
    }
}
