//
//  FakeCalendarProvider.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. In-memory, fully deterministic
//  `CalendarProviding` conformer — never touches `EKEventStore`, so it's safe both from
//  `KueTests` (requirement 41, `@testable import Kue`) and, launch-configured via
//  `uiTestLaunchArgument`, from inside the real app process driven by `KueUITests`
//  (requirement 43/44: "launch-configured fake Calendar services," "must not access the real
//  EventKit database"). Lives in the main target (not KueTests) specifically so `KueApp` can
//  install it in place of `SystemCalendarProvider` when that launch argument is present — the
//  same pattern `ModelContainerFactory.uiTestLaunchArgument`/`isUITestIsolatedStore` already
//  establishes for store isolation.
//

import Foundation

@MainActor
final class FakeCalendarProvider: CalendarProviding {
    /// Set via `XCUIApplication.launchArguments` by `KueUITests` cases that exercise Calendar
    /// flows, and only there — a normal launch never passes this, so `KueApp` always installs
    /// the real `SystemCalendarProvider` otherwise.
    static let uiTestLaunchArgument = "-uiTestFakeCalendar"
    /// Requirement 42: UI tests for the denied/restricted/not-determined presentations need a
    /// fake that starts in that exact state instead of `makeUITestFixture()`'s default
    /// `.fullAccess` — these three optional, additional launch arguments (only meaningful
    /// alongside `uiTestLaunchArgument`) select that starting state. Must match
    /// `UITestLaunchConfiguration`'s equivalents exactly.
    static let uiTestDeniedArgument = "-uiTestFakeCalendarDenied"
    static let uiTestRestrictedArgument = "-uiTestFakeCalendarRestricted"
    static let uiTestNotDeterminedArgument = "-uiTestFakeCalendarNotDetermined"
    /// Requirement 42 — "missing-event handling" / "conflict handling" presentations.
    /// `KueApp` (only inside the isolated UI-test store, only when present) seeds one `KueEvent`
    /// already linked to an identifier this fixture deliberately omits (`.missing`), and one
    /// already linked to `conflictEventExternalIdentifier` below, whose fixture
    /// `lastModifiedDate` is set to `.distantFuture` so it always reads as externally modified
    /// regardless of real launch timing.
    static let uiTestPreLinkedMissingArgument = "-uiTestFakeCalendarPreLinkedMissing"
    static let uiTestPreLinkedConflictArgument = "-uiTestFakeCalendarPreLinkedConflict"
    static let conflictEventExternalIdentifier = "fake-ext-conflict"

    var stateToReturn: CalendarAuthorizationState
    var requestAccessResult: CalendarAuthorizationState
    private(set) var requestAccessCallCount = 0
    var writableCalendarsToReturn: [KueWritableCalendar]
    var events: [KueCalendarEvent]
    /// When set, the next `save(_:in:)` call throws this instead of succeeding — requirement
    /// 41's "EventKit failure" coverage.
    var saveErrorToThrow: CalendarOperationError?
    private(set) var saveCallCount = 0

    init(
        stateToReturn: CalendarAuthorizationState = .notDetermined,
        requestAccessResult: CalendarAuthorizationState = .fullAccess,
        writableCalendars: [KueWritableCalendar] = [],
        events: [KueCalendarEvent] = []
    ) {
        self.stateToReturn = stateToReturn
        self.requestAccessResult = requestAccessResult
        self.writableCalendarsToReturn = writableCalendars
        self.events = events
    }

    func authorizationState() -> CalendarAuthorizationState { stateToReturn }

    func requestAccess() async -> CalendarAuthorizationState {
        requestAccessCallCount += 1
        stateToReturn = requestAccessResult
        return stateToReturn
    }

    func writableCalendars() -> [KueWritableCalendar] { writableCalendarsToReturn }

    func fetchEvents(from startDate: Date, to endDate: Date) -> [KueCalendarEvent] {
        guard stateToReturn.canReadEvents else { return [] }
        return events.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    func fetchEvent(externalIdentifier: String) -> KueCalendarEvent? {
        guard stateToReturn.canReadEvents else { return nil }
        return events.first { $0.externalIdentifier == externalIdentifier }
    }

    @discardableResult
    func save(_ event: KueCalendarEvent, in calendarIdentifier: String?) throws -> KueCalendarEvent {
        saveCallCount += 1
        if let saveErrorToThrow { throw saveErrorToThrow }
        guard stateToReturn.canWriteEvents else { throw CalendarOperationError.notAuthorized }

        var saved = event
        if let index = events.firstIndex(where: { $0.externalIdentifier == event.externalIdentifier }) {
            saved.lastModifiedDate = .now
            events[index] = saved
        } else {
            guard let calendarIdentifier, let calendar = writableCalendarsToReturn.first(where: { $0.calendarIdentifier == calendarIdentifier }) else {
                throw CalendarOperationError.calendarNotFound
            }
            saved.calendarIdentifier = calendar.calendarIdentifier
            saved.calendarTitle = calendar.title
            saved.lastModifiedDate = .now
            events.append(saved)
        }
        return saved
    }

    // MARK: - Launch-argument selection (requirement 42/43)

    /// `nil` when `uiTestLaunchArgument` isn't present at all — the caller (`KueApp`) falls
    /// back to the real `SystemCalendarProvider` in that case. Otherwise picks the fixture
    /// state the specific test asked for, defaulting to the full-access fixture.
    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeCalendarProvider? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        if arguments.contains(uiTestDeniedArgument) {
            return FakeCalendarProvider(stateToReturn: .denied, requestAccessResult: .denied)
        }
        if arguments.contains(uiTestRestrictedArgument) {
            return FakeCalendarProvider(stateToReturn: .restricted, requestAccessResult: .restricted)
        }
        if arguments.contains(uiTestNotDeterminedArgument) {
            let fixture = makeUITestFixture()
            return FakeCalendarProvider(stateToReturn: .notDetermined, requestAccessResult: .fullAccess, writableCalendars: fixture.writableCalendarsToReturn, events: fixture.events)
        }
        return makeUITestFixture()
    }

    // MARK: - Deterministic UI-test fixture (requirement 44: never the real EventKit database)

    /// One writable calendar plus four representative events — a plain timed meeting, a
    /// multi-day all-day trip, a fully-supported weekly recurrence, and an unsupported
    /// (multiple-rule) recurrence — enough for `KueUITests` to exercise every import/
    /// authorization-gated flow deterministically, keyed to fixed titles the tests assert
    /// against directly.
    static func makeUITestFixture() -> FakeCalendarProvider {
        let calendar = KueWritableCalendar(calendarIdentifier: "fake-calendar-home", title: "Fake Calendar Home", sourceTitle: "Fake Account")
        let reference = Calendar(identifier: .gregorian).startOfDay(for: .now).addingTimeInterval(9 * 3600)

        let meeting = KueCalendarEvent(
            externalIdentifier: "fake-ext-meeting",
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: "Fake Calendar Meeting",
            startDate: reference.addingTimeInterval(2 * 86_400),
            endDate: reference.addingTimeInterval(2 * 86_400 + 3_600),
            isAllDay: false,
            location: "Fake Conference Room",
            notes: "Fake meeting notes",
            timeZoneIdentifier: "America/New_York",
            lastModifiedDate: .now,
            recurrence: nil
        )

        let trip = KueCalendarEvent(
            externalIdentifier: "fake-ext-trip",
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: "Fake Calendar Trip",
            startDate: Calendar(identifier: .gregorian).startOfDay(for: reference.addingTimeInterval(10 * 86_400)),
            endDate: Calendar(identifier: .gregorian).startOfDay(for: reference.addingTimeInterval(13 * 86_400)),
            isAllDay: true,
            location: nil,
            notes: nil,
            timeZoneIdentifier: nil,
            lastModifiedDate: .now,
            recurrence: nil
        )

        let weeklySync = KueCalendarEvent(
            externalIdentifier: "fake-ext-weekly",
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: "Fake Calendar Weekly Sync",
            startDate: reference.addingTimeInterval(1 * 86_400),
            endDate: reference.addingTimeInterval(1 * 86_400 + 1_800),
            isAllDay: false,
            location: nil,
            notes: nil,
            timeZoneIdentifier: "America/Los_Angeles",
            lastModifiedDate: .now,
            recurrence: CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .weekly, interval: 1, end: .never), isFullySupported: true)
        )

        let complexRecurrence = KueCalendarEvent(
            externalIdentifier: "fake-ext-complex",
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: "Fake Calendar Complex Recurrence",
            startDate: reference.addingTimeInterval(3 * 86_400),
            endDate: reference.addingTimeInterval(3 * 86_400 + 3_600),
            isAllDay: false,
            location: nil,
            notes: nil,
            timeZoneIdentifier: "UTC",
            lastModifiedDate: .now,
            recurrence: CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .weekly, interval: 1, end: .never), isFullySupported: false)
        )

        let conflictEvent = KueCalendarEvent(
            externalIdentifier: conflictEventExternalIdentifier,
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: "Fake Calendar Conflict Event (changed externally)",
            startDate: reference.addingTimeInterval(4 * 86_400),
            endDate: reference.addingTimeInterval(4 * 86_400 + 3_600),
            isAllDay: false,
            location: nil,
            notes: nil,
            timeZoneIdentifier: "UTC",
            lastModifiedDate: .distantFuture,
            recurrence: nil
        )

        return FakeCalendarProvider(
            stateToReturn: .fullAccess,
            requestAccessResult: .fullAccess,
            writableCalendars: [calendar],
            events: [meeting, trip, weeklySync, complexRecurrence, conflictEvent]
        )
    }
}
