//
//  EventDuplicationService.swift
//  Kue
//
//  Kue 2.0 Phase 2, requirement 9/10 — "Duplicate Event" from Event Detail. App-only (not
//  Shared/): reaches `NotificationEngine`'s full cap-aware reschedule pass, same reason
//  `EventActions`/`EventFormView.save()` are app-only — the widget extension's own App
//  Intents (WidgetIntentActions.swift, Shared/) never need to duplicate an event.
//
//  What's copied vs. reset, per requirement 10:
//  - Copied: every user-editable KueEvent field (title, eventType, startDate, endDate,
//    estimatedDurationMinutes, isAllDay, timeZoneIdentifier, location, notes, priority,
//    recurrence), and KueSchedule.rules/isCustom/templateType (so a customized schedule
//    stays customized on the duplicate) and WidgetConfiguration's own settings.
//  - Reset to fresh defaults: id, createdAt/updatedAt, status/isCancelled/cancelledAt/
//    isManuallyCompleted/manuallyCompletedAt (KueEvent's own `init` defaults already do
//    this — simply never passing the source's values here *is* "not copy archived,
//    cancelled, or manually completed state"), and every KueTask (regenerated from scratch
//    by SchedulingEngine.regenerateTasks below, so none are completed and none are shared
//    with the source).
//  - `source` is deliberately set to `.manual`, not copied from the original — duplication
//    is itself a fresh manual action, not a re-parse of NL/Share Sheet input, regardless of
//    how the original event was created.
//  - `WidgetState` is never copied (or created) for the duplicate — see
//    docs/14-open-questions.md "Resolved by what actually shipped": `WidgetState` stays
//    unpopulated everywhere in V1, not something this phase should start populating.
//

import Foundation
import SwiftData

enum EventDuplicationService {
    struct Outcome {
        var newEvent: KueEvent
        /// Requirement: "run duplicate detection." Since the duplicate necessarily shares
        /// its source's title and calendar day, this is almost always the source event
        /// itself — surfaced to the caller exactly like `EventFormView`'s own duplicate
        /// banner, not silently discarded.
        var detectedDuplicate: KueEvent?
    }

    /// Creates and persists an independent copy of `event`. Regenerates tasks through
    /// `SchedulingEngine` (never copies `KueTask` rows directly — requirement: "regenerate
    /// tasks through SchedulingEngine," "not copy task-completion state," "produce
    /// independent task/schedule/widget relationships"), reschedules notifications, and
    /// reloads the widget timeline, mirroring the exact sequence `EventFormView.save()`
    /// already uses for a brand-new event.
    @discardableResult
    static func duplicate(
        _ event: KueEvent,
        context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        widgetReloader: WidgetReloading = SystemWidgetReloader.shared,
        now: Date = .now
    ) async -> Outcome {
        let newEvent = KueEvent(
            title: event.title,
            eventType: event.eventType,
            startDate: event.startDate,
            endDate: event.endDate,
            estimatedDurationMinutes: event.estimatedDurationMinutes,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: event.location,
            notes: event.notes,
            source: .manual,
            priority: event.priority,
            // Kue 2.0 Phase 3: deliberately NOT `event.recurrence` — a duplicate is always a
            // plain, independent, non-recurring copy (no seriesID/recurrenceAnchorDate is
            // generated for it either), matching "duplication is itself a fresh manual action"
            // for the same reason `source` is reset rather than copied. Copying the rule
            // without also spinning up a whole new materialized series would leave the
            // duplicate in an inconsistent "recurring but seriesID == nil" state; see
            // docs/17-recurring-events.md.
            recurrence: nil,
            createdAt: now,
            updatedAt: now
        )
        context.insert(newEvent)
        EventStatusEngine.reconcile(newEvent, now: now)

        if let sourceSchedule = event.schedule {
            let newSchedule = KueSchedule(
                event: newEvent,
                templateType: sourceSchedule.templateType,
                rules: sourceSchedule.rules,
                isCustom: sourceSchedule.isCustom,
                generatedAt: now
            )
            context.insert(newSchedule)
            newEvent.schedule = newSchedule
        }
        // No source schedule at all (shouldn't happen for a real event, but defensive):
        // `SchedulingEngine.regenerateTasks` below seeds a fresh default one itself, the same
        // fallback path every other call site relies on.

        let widgetType = event.widgetConfiguration?.widgetType ?? WidgetType.defaultType(for: newEvent.eventType)
        let showLocation = event.widgetConfiguration?.showLocation ?? true
        let isEnabled = event.widgetConfiguration?.isEnabled ?? true
        let newWidgetConfiguration = WidgetConfiguration(
            event: newEvent,
            widgetType: widgetType,
            showLocation: showLocation,
            isEnabled: isEnabled
        )
        context.insert(newWidgetConfiguration)
        newEvent.widgetConfiguration = newWidgetConfiguration

        // Fresh, non-completed tasks from `newEvent.schedule.rules` — `newEvent.tasks` starts
        // empty, so nothing here can be mistaken for a "preserved completed task."
        SchedulingEngine.regenerateTasks(for: newEvent, context: context, now: now)

        let existingEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let detectedDuplicate = DuplicateDetectionService.findDuplicate(
            title: newEvent.title,
            startDate: newEvent.startDate,
            timeZoneIdentifier: newEvent.timeZoneIdentifier,
            excluding: newEvent.id,
            in: existingEvents
        )

        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)

        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(
            context: context,
            intensity: intensity,
            scheduler: scheduler,
            now: now,
            requestPermissionIfNeeded: true
        )

        return Outcome(newEvent: newEvent, detectedDuplicate: detectedDuplicate)
    }
}
