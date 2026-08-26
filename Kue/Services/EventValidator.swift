//
//  EventValidator.swift
//  Kue
//
//  Deterministic, non-AI validation for the manual entry form — see
//  docs/13-error-handling.md "Error messaging must always be specific." One case per
//  distinct problem, no shared generic error.
//

import Foundation

/// Editable draft backing the Add/Edit form — see EventFormView.swift. Deliberately not
/// `KueEvent` itself: a draft can be transiently invalid (empty title, missing trip end
/// date) while the user is still typing, which `KueEvent`'s non-optional fields don't allow.
struct EventDraft {
    var title: String = ""
    var eventType: EventType = .generic
    var startDate: Date = .now
    var isAllDay: Bool = false
    /// Required for `.trip`, ignored otherwise.
    var endDate: Date = .now.addingTimeInterval(86_400)
    var location: String = ""
    var notes: String = ""
    var priority: Priority = .medium
    var timeZoneIdentifier: String = TimeZone.current.identifier
}

enum EventValidationError: LocalizedError, Equatable, Identifiable {
    case titleRequired
    case tripEndDateBeforeStart

    var id: String { errorDescription ?? "" }

    var errorDescription: String? {
        switch self {
        case .titleRequired:
            return "Give this event a title."
        case .tripEndDateBeforeStart:
            return "The return date can't be before the start date."
        }
    }
}

enum EventValidator {
    /// Empty when the draft is valid. `.trip`'s end date is always present in `EventDraft`
    /// (defaulted), so the only trip-specific failure is ordering, not absence.
    static func validate(_ draft: EventDraft) -> [EventValidationError] {
        var errors: [EventValidationError] = []

        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.titleRequired)
        }

        if draft.eventType == .trip, draft.endDate < draft.startDate {
            errors.append(.tripEndDateBeforeStart)
        }

        return errors
    }
}

extension EventType {
    /// docs/03-data-model.md "Completion timing" default table. `.trip` doesn't use this —
    /// it always has an explicit `endDate`.
    var defaultEstimatedDurationMinutes: Int {
        switch self {
        case .generic, .deadline: return 0
        case .exam: return 120
        case .interview: return 60
        case .trip: return 0
        }
    }

    var displayName: String {
        switch self {
        case .generic: return "Generic"
        case .deadline: return "Deadline"
        case .exam: return "Exam"
        case .interview: return "Interview"
        case .trip: return "Trip"
        }
    }
}
