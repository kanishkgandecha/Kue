//
//  CalendarImportPipeline.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. See docs/18-calendar-integration.md "Import
//  pipeline" — the same "raw input → convert → normalize → editable draft" shape
//  `NLParsingPipeline` establishes (docs/06-ai-layer.md "Pipeline"), applied to a selected
//  `KueCalendarEvent` instead of parsed text. Requirement 11: imported values pass through
//  Kue's deterministic normalization exactly like every other input path — nothing here is
//  AI/heuristic, every mapping rule is fixed and testable.
//

import Foundation

/// Requirement 36 — the user's explicit choice for a recurring Calendar event, made before a
/// draft is ever built.
enum CalendarImportRecurrenceChoice {
    case singleOccurrenceOnly
    case convertToSeries
}

enum CalendarImportPipeline {
    struct Outcome {
        var draft: EventDraft
        /// Requirement 37 — set whenever the source rule couldn't be represented exactly, so
        /// the caller can show it even if the user chose `.singleOccurrenceOnly` (nothing was
        /// silently dropped without saying so).
        var recurrenceLimitationMessage: String?
    }

    /// Requirement 35 — multi-day handling: a Calendar event whose all-day span covers more
    /// than one calendar day is deterministically imported as `.trip` (the only Kue event type
    /// with span/return-date semantics), so its full length survives into the draft rather than
    /// being silently truncated to a single day. Every other Calendar event imports as
    /// `.generic` — freely changeable in the still-editable draft (requirement 12) before saving.
    static func draft(from calendarEvent: KueCalendarEvent, recurrenceChoice: CalendarImportRecurrenceChoice) -> Outcome {
        var draft = EventDraft()
        draft.title = calendarEvent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.isAllDay = calendarEvent.isAllDay
        draft.location = calendarEvent.location ?? ""
        draft.notes = calendarEvent.notes ?? ""

        // Requirement 33/34 — all-day events carry no timezone at all (date-only semantics,
        // matching KueEvent.isAllDay's own contract in Shared/Models/KueEvent.swift); a timed
        // event's *source* timezone is pinned into the draft exactly as Kue already pins
        // `timeZoneIdentifier` at creation for every other input path — never silently
        // reinterpreted against the device's current timezone.
        let sourceTimeZoneIdentifier = calendarEvent.timeZoneIdentifier ?? TimeZone.current.identifier
        draft.timeZoneIdentifier = sourceTimeZoneIdentifier

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = calendarEvent.isAllDay ? .gmt : (TimeZone(identifier: sourceTimeZoneIdentifier) ?? .current)

        // EventKit's all-day `endDate` is exclusive (the day *after* the last covered day), so
        // a single-day all-day event already has a one-day gap between start and end — only a
        // gap greater than one day is genuinely multi-day.
        let spansMultipleDays = calendarEvent.isAllDay
            && calendar.dateComponents([.day], from: calendar.startOfDay(for: calendarEvent.startDate), to: calendar.startOfDay(for: calendarEvent.endDate)).day ?? 0 > 1

        draft.eventType = spansMultipleDays ? .trip : .generic
        draft.startDate = calendarEvent.startDate
        if spansMultipleDays {
            // EventKit's all-day `endDate` is exclusive (midnight the day *after* the last
            // day) — Kue's `.trip` end date is the last inclusive day, matching how the rest
            // of the app (e.g. OccurrenceReconciliationService's own `.trip` length math)
            // already treats end dates as inclusive calendar days.
            draft.endDate = calendar.date(byAdding: .day, value: -1, to: calendarEvent.endDate) ?? calendarEvent.endDate
        } else {
            draft.endDate = calendarEvent.endDate
        }

        draft.externalCalendarEventIdentifier = calendarEvent.externalIdentifier
        draft.externalCalendarIdentifier = calendarEvent.calendarIdentifier
        draft.externalCalendarTitle = calendarEvent.calendarTitle
        draft.externalCalendarLastKnownModifiedAt = calendarEvent.lastModifiedDate

        var limitationMessage: String?
        if let recurrence = calendarEvent.recurrence {
            if !recurrence.isFullySupported {
                limitationMessage = "This event repeats in a way Kue can't fully represent — only this single occurrence can be imported."
            } else if recurrenceChoice == .convertToSeries {
                draft.applyRecurrenceRule(recurrence.mapped)
            }
            // `.singleOccurrenceOnly` (or an unsupported rule regardless of the requested
            // choice — requirement 37: never import an unsupported rule inaccurately) leaves
            // `draft.isRecurring == false`, i.e. this one occurrence only.
        }

        return Outcome(draft: draft, recurrenceLimitationMessage: limitationMessage)
    }
}
