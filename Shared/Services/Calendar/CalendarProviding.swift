//
//  CalendarProviding.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. Requirement 1: "all EventKit access behind
//  dependency-injected protocols." `SystemCalendarProvider` (real, `EKEventStore`-backed) and
//  `FakeCalendarProvider` (in-memory, requirement 41/43) are the only two conformers — every
//  view/service reaches Calendar exclusively through this protocol, injected via
//  `CalendarEnvironment.swift`'s `\.calendarProvider`, never by constructing either directly.
//

import Foundation

@MainActor
protocol CalendarProviding {
    /// Never itself requests access — a pure read of the current OS-level state. Requirement
    /// 6: nothing may call `requestAccess()` as a side effect of merely checking this.
    func authorizationState() -> CalendarAuthorizationState

    /// Requirement 5/6 — must only ever be called from a deliberate, contextual feature
    /// invocation (an explicit "Import from Calendar" / "Add to Apple Calendar" tap, or the
    /// Settings Calendar section's own "Allow Access" button), never at launch or from generic
    /// onboarding. Returns the resulting state so the caller can react immediately.
    func requestAccess() async -> CalendarAuthorizationState

    /// Every calendar the user could write an exported event into (requirement 18) —
    /// `allowsContentModifications == true` only. Empty (never throws) when access doesn't
    /// permit writing.
    func writableCalendars() -> [KueWritableCalendar]

    /// Events in `[startDate, endDate)` for the import list (requirement 7/8). Empty (never
    /// throws) when access doesn't permit reading — callers gate the whole import UI on
    /// `authorizationState().canReadEvents` first, so this is a defensive fallback, not the
    /// primary gate.
    func fetchEvents(from startDate: Date, to endDate: Date) -> [KueCalendarEvent]

    /// A single event by its stable external identifier — used to check link status
    /// (requirement 26): missing, moved, or externally modified. `nil` (never throws) if it no
    /// longer exists or can't be read.
    func fetchEvent(externalIdentifier: String) -> KueCalendarEvent?

    /// Creates (when `event.externalIdentifier` doesn't yet resolve to a real Calendar event)
    /// or updates (when it does) a Calendar event from `event`'s fields, in `calendarIdentifier`
    /// when creating. Returns the saved event's own external identifier and `lastModifiedDate`
    /// so the caller can persist an accurate link. Throws rather than silently no-oping on
    /// failure (requirement: "Calendar failures must never damage Kue data" — the caller must
    /// only update `KueEvent` after this actually succeeds).
    @discardableResult
    func save(_ event: KueCalendarEvent, in calendarIdentifier: String?) throws -> KueCalendarEvent
}
