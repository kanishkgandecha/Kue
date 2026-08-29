//
//  CalendarEnvironment.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. Dependency injection for `CalendarProviding`
//  — views read `\.calendarProvider` from the SwiftUI environment rather than constructing a
//  `SystemCalendarProvider` themselves, mirroring `AIEnvironment.swift`'s `\.nlParser` seam
//  exactly, so KueTests/previews/UI-test-launch-configuration can supply a
//  `FakeCalendarProvider` and never invoke real EventKit. `KueApp` installs the real
//  implementation at the root (or, when launched with
//  `FakeCalendarProvider.uiTestLaunchArgument`, a deterministic fake — see that type's own
//  header).
//

import SwiftUI

private struct CalendarProviderKey: EnvironmentKey {
    /// No-op default (always `.unavailable`, never touches EventKit) so a context that never
    /// sets this — a preview, an unrelated test — still compiles and reports "unavailable"
    /// rather than crashing.
    static let defaultValue: CalendarProviding = UnavailableCalendarProvider()
}

extension EnvironmentValues {
    var calendarProvider: CalendarProviding {
        get { self[CalendarProviderKey.self] }
        set { self[CalendarProviderKey.self] = newValue }
    }
}

@MainActor
private struct UnavailableCalendarProvider: CalendarProviding {
    func authorizationState() -> CalendarAuthorizationState { .unavailable }
    func requestAccess() async -> CalendarAuthorizationState { .unavailable }
    func writableCalendars() -> [KueWritableCalendar] { [] }
    func fetchEvents(from startDate: Date, to endDate: Date) -> [KueCalendarEvent] { [] }
    func fetchEvent(externalIdentifier: String) -> KueCalendarEvent? { nil }
    func save(_ event: KueCalendarEvent, in calendarIdentifier: String?) throws -> KueCalendarEvent {
        throw CalendarOperationError.notAuthorized
    }
}
