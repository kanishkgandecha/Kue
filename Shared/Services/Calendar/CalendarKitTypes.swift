//
//  CalendarKitTypes.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. See docs/18-calendar-integration.md
//  "EventKit abstraction". Requirement 2: "EventKit types stay at the integration boundary" —
//  everything in this file is a plain, Kue-owned value type. Nothing outside
//  SystemCalendarProvider.swift ever imports EventKit or names `EKEvent`/`EKCalendar`/
//  `EKEventStore`/`EKAuthorizationStatus` directly.
//

import Foundation

/// Requirement 4 — every authorization state EventKit can report, handled distinctly. iOS 17+
/// splits `.authorized` into full and write-only access (`EKAuthorizationStatus.fullAccess`/
/// `.writeOnly`); `.unavailable` covers a platform/policy state with no calendar access at all
/// (e.g. Screen Time restrictions reporting something EventKit itself can't classify);
/// `.unknown` is the forward-compatibility fallback for any future `EKAuthorizationStatus` case
/// this app doesn't recognize yet — never silently treated as any of the known states.
enum CalendarAuthorizationState: Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted
    case unavailable
    case unknown

    /// Reading existing events (import) requires full access — write-only access can create/
    /// update but can never fetch, per EventKit's own contract.
    var canReadEvents: Bool { self == .fullAccess }
    /// Both full and write-only access can create/update calendar events.
    var canWriteEvents: Bool { self == .fullAccess || self == .writeOnly }

    /// docs/18-calendar-integration.md "Settings" — the concise, state-specific explanation
    /// requirement 3 calls for. `nil` for `.fullAccess`/`.writeOnly` — nothing to explain once
    /// access already does what's needed.
    var explanation: String? {
        switch self {
        case .notDetermined:
            return "Kue can import events from Apple Calendar into editable drafts, and add or update events you explicitly export — nothing happens automatically, and nothing is read until you choose to import."
        case .fullAccess:
            return nil
        case .writeOnly:
            return "Kue can add and update events in Apple Calendar, but can't read your existing events to import them. Grant full access in Settings to also import."
        case .denied:
            return "Calendar access is off. Turn it on in Settings to import events or add Kue events to your calendar."
        case .restricted:
            return "Calendar access is restricted on this device (e.g. by Screen Time) and can't be changed here."
        case .unavailable:
            return "Calendar access isn't available on this device."
        case .unknown:
            return "Kue can't determine Calendar access on this device."
        }
    }
}

/// Requirement 10 — a Kue-owned snapshot of exactly what an import/status-check needs from an
/// `EKEvent`, nothing more. `externalIdentifier` is `EKEvent.calendarItemExternalIdentifier`
/// (stable across devices), not `eventIdentifier` (can change on a given device).
struct KueCalendarEvent: Equatable {
    var externalIdentifier: String
    var calendarIdentifier: String
    var calendarTitle: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    /// Source timezone — requirement 10/34. `nil` for an all-day event, which EventKit itself
    /// treats as timezone-less date-only data.
    var timeZoneIdentifier: String?
    var lastModifiedDate: Date?
    var recurrence: CalendarRecurrenceInfo?
}

/// Requirement 36/37 — a best-effort mapping of `EKEvent.recurrenceRules` into Kue's own
/// `RecurrenceRule` shape. `isFullySupported == false` means the source rule uses something
/// Kue's model can't represent exactly (multiple rules, by-day/by-set-position lists, an
/// interval Kue doesn't model, etc.) — `mapped` is still populated on a best-effort basis so
/// callers *could* preview it, but the import UI must never silently offer "convert to series"
/// for an unsupported rule; only single-occurrence import is offered.
struct CalendarRecurrenceInfo: Equatable {
    var mapped: RecurrenceRule
    var isFullySupported: Bool
}

/// Requirement 18 — a Kue-owned snapshot of `EKCalendar` sufficient to let the user pick a
/// destination for export. Only calendars EventKit itself reports as `allowsContentModifications`
/// should ever appear in `CalendarProviding.writableCalendars()`.
struct KueWritableCalendar: Equatable, Identifiable {
    var id: String { calendarIdentifier }
    var calendarIdentifier: String
    var title: String
    var sourceTitle: String
}

/// Requirement: "Calendar failures must never damage Kue data." Every `CalendarProviding`
/// method that can fail throws one of these — callers (`CalendarExportService`) catch it, leave
/// the `KueEvent` untouched, and surface a specific message, never a generic one
/// (docs/13-error-handling.md).
enum CalendarOperationError: LocalizedError, Equatable {
    case notAuthorized
    case eventNotFound
    case calendarNotFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Kue doesn't have permission to access Calendar."
        case .eventNotFound:
            return "That Calendar event can no longer be found."
        case .calendarNotFound:
            return "That calendar is no longer available."
        case .saveFailed(let reason):
            return "Couldn't save to Calendar: \(reason)"
        }
    }
}
