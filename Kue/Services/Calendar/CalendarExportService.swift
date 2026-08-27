//
//  CalendarExportService.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. See docs/18-calendar-integration.md "Export
//  and update". Every method here either succeeds and updates exactly the five
//  Calendar-linkage fields on `KueEvent` (requirement 20), or fails and leaves `KueEvent`
//  completely untouched (requirement 32: "Calendar failures must never damage Kue data") —
//  nothing in this file ever touches tasks, schedule, recurrence, notifications, or the widget.
//  Kue never writes a recurrence rule back to Calendar: each linked Kue occurrence (recurring
//  or not) exports as one independent Calendar event, matching the product contract's "no
//  implicit two-way synchronization" — a materialized series occurrence is already just an
//  ordinary `KueEvent` row (docs/17-recurring-events.md), so this needs no special case.
//

import Foundation
import SwiftData

/// Requirement 26/28 — what `status(for:)` finds when checking a linked event before
/// presenting "Update Calendar Event."
enum CalendarLinkStatus: Equatable {
    case notLinked
    case linked
    /// Requirement 26/27 — no longer exists, moved to an inaccessible calendar, or otherwise
    /// can't be found by its stable external identifier.
    case missing
    /// Requirement 26/28/29 — found, but its `lastModifiedDate` has moved past what Kue last
    /// recorded: something changed it outside Kue since. Carries the live Calendar-side
    /// snapshot so the caller can show a real conflict summary, not a vague warning.
    case externallyModified(KueCalendarEvent)
}

enum CalendarExportService {
    static func status(for event: KueEvent, provider: CalendarProviding) -> CalendarLinkStatus {
        guard let externalID = event.externalCalendarEventIdentifier else { return .notLinked }
        guard let fetched = provider.fetchEvent(externalIdentifier: externalID) else { return .missing }
        if let lastKnown = event.externalCalendarLastKnownModifiedAt,
           let fetchedModified = fetched.lastModifiedDate,
           fetchedModified > lastKnown {
            return .externallyModified(fetched)
        }
        return .linked
    }

    /// Requirement 17/19/20 — first export to a chosen destination calendar. A fresh external
    /// identifier is minted here (not by `CalendarProviding`) so the caller can always tell
    /// create-vs-update apart from the `KueEvent` side alone.
    @discardableResult
    static func export(
        _ event: KueEvent,
        to calendar: KueWritableCalendar,
        provider: CalendarProviding,
        context: ModelContext,
        now: Date = .now
    ) -> Result<Void, CalendarOperationError> {
        let calendarEvent = makeCalendarEvent(from: event, externalIdentifier: UUID().uuidString, calendarIdentifier: calendar.calendarIdentifier)
        return perform(calendarEvent, in: calendar.calendarIdentifier, provider: provider, event: event, context: context, now: now)
    }

    /// Requirement 24/25 — only valid for an already-linked event; explicit, never automatic.
    @discardableResult
    static func update(
        _ event: KueEvent,
        provider: CalendarProviding,
        context: ModelContext,
        now: Date = .now
    ) -> Result<Void, CalendarOperationError> {
        guard let externalID = event.externalCalendarEventIdentifier, let calendarID = event.externalCalendarIdentifier else {
            return .failure(.eventNotFound)
        }
        let calendarEvent = makeCalendarEvent(from: event, externalIdentifier: externalID, calendarIdentifier: calendarID)
        return perform(calendarEvent, in: calendarID, provider: provider, event: event, context: context, now: now)
    }

    /// Requirement 27 — offered when `status(for:) == .missing`. Creates a brand-new Calendar
    /// event (the old external identifier is gone) in the same calendar the link previously
    /// pointed at, and re-links to it.
    @discardableResult
    static func recreate(
        _ event: KueEvent,
        provider: CalendarProviding,
        context: ModelContext,
        now: Date = .now
    ) -> Result<Void, CalendarOperationError> {
        guard let calendarID = event.externalCalendarIdentifier else { return .failure(.calendarNotFound) }
        let calendarEvent = makeCalendarEvent(from: event, externalIdentifier: UUID().uuidString, calendarIdentifier: calendarID)
        return perform(calendarEvent, in: calendarID, provider: provider, event: event, context: context, now: now)
    }

    /// Requirement 30 — removes only Kue's own reference; never asks `provider` to delete
    /// anything, so the Calendar event itself is untouched.
    static func unlink(_ event: KueEvent, context: ModelContext) {
        event.externalCalendarEventIdentifier = nil
        event.externalCalendarIdentifier = nil
        event.externalCalendarTitle = nil
        event.externalCalendarLastSyncedAt = nil
        event.externalCalendarLastKnownModifiedAt = nil
        try? context.save()
    }

    // MARK: - Shared save path

    private static func perform(
        _ calendarEvent: KueCalendarEvent,
        in calendarIdentifier: String,
        provider: CalendarProviding,
        event: KueEvent,
        context: ModelContext,
        now: Date
    ) -> Result<Void, CalendarOperationError> {
        do {
            let saved = try provider.save(calendarEvent, in: calendarIdentifier)
            // Only reached on confirmed success — a thrown error below leaves every one of
            // these fields, and everything else about `event`, exactly as it was.
            event.externalCalendarEventIdentifier = saved.externalIdentifier
            event.externalCalendarIdentifier = saved.calendarIdentifier
            event.externalCalendarTitle = saved.calendarTitle
            event.externalCalendarLastSyncedAt = now
            event.externalCalendarLastKnownModifiedAt = saved.lastModifiedDate ?? now
            try? context.save()
            return .success(())
        } catch let error as CalendarOperationError {
            return .failure(error)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Requirement 33/34 — a `KueEvent` timed event exports with its own pinned
    /// `timeZoneIdentifier`, never the device's current timezone; an all-day event exports
    /// with no timezone at all, matching EventKit's own all-day contract.
    private static func makeCalendarEvent(from event: KueEvent, externalIdentifier: String, calendarIdentifier: String) -> KueCalendarEvent {
        KueCalendarEvent(
            externalIdentifier: externalIdentifier,
            calendarIdentifier: calendarIdentifier,
            calendarTitle: event.externalCalendarTitle ?? "",
            title: event.title,
            startDate: event.startDate,
            endDate: event.effectiveEndDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZoneIdentifier,
            lastModifiedDate: nil,
            recurrence: nil
        )
    }
}
