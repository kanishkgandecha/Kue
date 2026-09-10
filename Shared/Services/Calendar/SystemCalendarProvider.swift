//
//  SystemCalendarProvider.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. The one file in this app that imports
//  EventKit and touches `EKEventStore` directly — requirement 1/2. Every method translates
//  immediately to/from the Kue-owned value types in CalendarKitTypes.swift; no `EKEvent`/
//  `EKCalendar` ever escapes this file.
//

import Foundation
import EventKit

@MainActor
final class SystemCalendarProvider: CalendarProviding {
    private let store = EKEventStore()

    func authorizationState() -> CalendarAuthorizationState {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAuthorizationState {
        // Requirement 4 — iOS 17+ splits full vs. write-only access; request full (Kue needs
        // to read for import, not just write for export). `requestFullAccessToEvents` is the
        // only call this app ever makes that can trigger the system permission prompt.
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Falls through to re-reading the real post-request state below regardless —
            // EventKit throwing here (rare; usually Info.plist misconfiguration) still leaves
            // `authorizationStatus(for:)` as the source of truth, not this catch block.
        }
        return authorizationState()
    }

    func writableCalendars() -> [KueWritableCalendar] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { KueWritableCalendar(calendarIdentifier: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title) }
    }

    func fetchEvents(from startDate: Date, to endDate: Date) -> [KueCalendarEvent] {
        guard authorizationState().canReadEvents else { return [] }
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return store.events(matching: predicate).map(Self.map)
    }

    func fetchEvent(externalIdentifier: String) -> KueCalendarEvent? {
        guard authorizationState().canReadEvents else { return nil }
        // EventKit has no direct "fetch by external identifier" lookup — only by the
        // (device-local, can change) `eventIdentifier`, or by scanning a date window. Scanning
        // a generously wide window is the deterministic, EventKit-contract-respecting way to
        // resolve a stable cross-device identifier back to a live event.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .year, value: -5, to: .now) ?? .now
        let end = calendar.date(byAdding: .year, value: 5, to: .now) ?? .now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .first { $0.calendarItemExternalIdentifier == externalIdentifier }
            .map(Self.map)
    }

    @discardableResult
    func save(_ event: KueCalendarEvent, in calendarIdentifier: String?) throws -> KueCalendarEvent {
        guard authorizationState().canWriteEvents else { throw CalendarOperationError.notAuthorized }

        let ekEvent: EKEvent
        if let existing = store.events(
            matching: store.predicateForEvents(
                withStart: Calendar.current.date(byAdding: .year, value: -5, to: .now) ?? .now,
                end: Calendar.current.date(byAdding: .year, value: 5, to: .now) ?? .now,
                calendars: nil
            )
        ).first(where: { $0.calendarItemExternalIdentifier == event.externalIdentifier }) {
            ekEvent = existing
        } else {
            ekEvent = EKEvent(eventStore: store)
            guard let calendarIdentifier, let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
                throw CalendarOperationError.calendarNotFound
            }
            ekEvent.calendar = calendar
        }

        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.isAllDay = event.isAllDay
        ekEvent.location = event.location
        ekEvent.notes = event.notes
        if let timeZoneIdentifier = event.timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            ekEvent.timeZone = timeZone
        }

        do {
            try store.save(ekEvent, span: .thisEvent)
        } catch {
            throw CalendarOperationError.saveFailed(error.localizedDescription)
        }

        return Self.map(ekEvent)
    }

    // MARK: - Mapping (requirement 2: EventKit types never escape this file)

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .authorized: return .fullAccess // pre-iOS-17 undifferentiated "authorized"
        @unknown default: return .unknown
        }
    }

    private static func map(_ event: EKEvent) -> KueCalendarEvent {
        KueCalendarEvent(
            externalIdentifier: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            calendarIdentifier: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            timeZoneIdentifier: event.isAllDay ? nil : (event.timeZone?.identifier ?? TimeZone.current.identifier),
            lastModifiedDate: event.lastModifiedDate,
            recurrence: mapRecurrence(event.recurrenceRules)
        )
    }

    /// Requirement 36/37 — only a *single* rule with no end-condition ambiguity and a
    /// day/week/month/year frequency (matching `RecurrenceRule.Frequency` exactly) with no
    /// by-day/by-month-day/by-set-position qualifiers is fully supported; anything else still
    /// gets a best-effort `mapped` value (frequency/interval only, `end: .never`) but
    /// `isFullySupported = false`, so the import UI can explain the limitation (requirement 37)
    /// rather than silently misrepresenting it.
    private static func mapRecurrence(_ rules: [EKRecurrenceRule]?) -> CalendarRecurrenceInfo? {
        guard let rules, rules.count == 1, let rule = rules.first else {
            guard let rules, !rules.isEmpty else { return nil }
            return CalendarRecurrenceInfo(mapped: RecurrenceRule(frequency: .weekly, interval: 1, end: .never), isFullySupported: false)
        }

        let frequency: RecurrenceRule.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .weekly
        }

        let hasUnsupportedQualifiers = (rule.daysOfTheWeek?.isEmpty == false)
            || (rule.daysOfTheMonth?.isEmpty == false)
            || (rule.monthsOfTheYear?.isEmpty == false)
            || (rule.setPositions?.isEmpty == false)
            || (rule.weeksOfTheYear?.isEmpty == false)
            || (rule.daysOfTheYear?.isEmpty == false)

        let end: RecurrenceRule.End
        if let untilDate = rule.recurrenceEnd?.endDate {
            end = .onDate(untilDate)
        } else if rule.recurrenceEnd?.occurrenceCount ?? 0 > 0 {
            end = .afterOccurrences(rule.recurrenceEnd!.occurrenceCount)
        } else {
            end = .never
        }

        let mapped = RecurrenceRule(frequency: frequency, interval: max(rule.interval, 1), end: end)
        return CalendarRecurrenceInfo(mapped: mapped, isFullySupported: !hasUnsupportedQualifiers)
    }
}
