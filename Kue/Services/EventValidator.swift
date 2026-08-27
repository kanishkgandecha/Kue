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

    // MARK: - Kue 2.0 Phase 3 — Recurrence (docs/17-recurring-events.md "UI")

    var isRecurring: Bool = false
    var recurrenceFrequency: RecurrenceRule.Frequency = .weekly
    var recurrenceInterval: Int = 1
    var recurrenceEndKind: RecurrenceEndKind = .never
    var recurrenceEndDate: Date = .now.addingTimeInterval(30 * 86_400)
    var recurrenceOccurrenceCount: Int = 10

    /// `nil` unless `isRecurring` — the actual rule EventFormView.save() persists.
    var recurrenceRule: RecurrenceRule? {
        guard isRecurring else { return nil }
        let end: RecurrenceRule.End
        switch recurrenceEndKind {
        case .never: end = .never
        case .onDate: end = .onDate(recurrenceEndDate)
        case .afterCount: end = .afterOccurrences(recurrenceOccurrenceCount)
        }
        return RecurrenceRule(frequency: recurrenceFrequency, interval: max(recurrenceInterval, 1), end: end)
    }

    /// Reverse of `recurrenceRule` — populates the draft's recurrence controls from an
    /// existing rule (editing a series occurrence under "This and Future").
    mutating func applyRecurrenceRule(_ rule: RecurrenceRule?) {
        guard let rule else {
            isRecurring = false
            return
        }
        isRecurring = true
        recurrenceFrequency = rule.frequency
        recurrenceInterval = rule.interval
        switch rule.end {
        case .never:
            recurrenceEndKind = .never
        case .onDate(let date):
            recurrenceEndKind = .onDate
            recurrenceEndDate = date
        case .afterOccurrences(let count):
            recurrenceEndKind = .afterCount
            recurrenceOccurrenceCount = count
        }
    }
}

/// UI-facing projection of `RecurrenceRule.End` — a plain `Codable` enum with an associated
/// value can't drive a SwiftUI `Picker`'s `selection` as cleanly as three flat cases plus the
/// separate `recurrenceEndDate`/`recurrenceOccurrenceCount` fields above.
enum RecurrenceEndKind: String, CaseIterable, Identifiable {
    case never, onDate, afterCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .onDate: return "On Date"
        case .afterCount: return "After"
        }
    }
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

    /// Kue 2.0 Phase 3 — separate from `validate(_:)` above so every existing call site (and
    /// EventDraft consumers with no recurrence UI, e.g. the Share Extension's prefilled path)
    /// is unaffected; EventFormView merges both error lists into one validation-errors section.
    static func validateRecurrence(_ draft: EventDraft) -> [RecurrenceValidationError] {
        guard let rule = draft.recurrenceRule else { return [] }
        return RecurrenceEngine.validate(rule, startDate: draft.startDate)
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
}
