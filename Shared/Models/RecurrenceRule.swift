//
//  RecurrenceRule.swift
//  Kue
//
//  Kue 2.0 Phase 3 — Recurring Events. See docs/17-recurring-events.md for the full contract.
//  A plain Codable struct (like ScheduleRule) stored as a KueEvent attribute, not a @Model — a
//  Codable helper struct's own shape never needs its own schema version
//  (docs/15-schema-migrations.md "What does *not* count"). `End` being a single-case enum makes
//  "end date and occurrence count are mutually exclusive" a type-level invariant: there is no
//  representable value with both set.
//

import Foundation

struct RecurrenceRule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable {
        case daily, weekly, monthly, yearly

        var displayName: String {
            switch self {
            case .daily: return "Day"
            case .weekly: return "Week"
            case .monthly: return "Month"
            case .yearly: return "Year"
            }
        }
    }

    /// Mutually exclusive by construction — see file header.
    enum End: Codable, Equatable {
        case never
        case onDate(Date)
        case afterOccurrences(Int)
    }

    var frequency: Frequency
    /// Must be >= 1 — see RecurrenceEngine.validate.
    var interval: Int
    var end: End

    /// docs/17-recurring-events.md "UI" — the human-readable summary shown before saving.
    /// Deterministic, locale-independent enough for tests (uses `Date.formatted` for the one
    /// date it renders, same as the rest of the app's display code).
    func summary(startDate: Date) -> String {
        let cadence: String
        if interval == 1 {
            cadence = "Every \(frequency.displayName.lowercased())"
        } else {
            cadence = "Every \(interval) \(frequency.displayName.lowercased())s"
        }

        switch end {
        case .never:
            return cadence
        case .onDate(let date):
            return "\(cadence) until \(date.formatted(date: .abbreviated, time: .omitted))"
        case .afterOccurrences(let count):
            return "\(cadence), \(count) time\(count == 1 ? "" : "s")"
        }
    }
}

enum RecurrenceValidationError: LocalizedError, Equatable, Identifiable {
    case intervalTooSmall
    case occurrenceCountTooSmall
    case endDateBeforeStart

    var id: String { errorDescription ?? "" }

    var errorDescription: String? {
        switch self {
        case .intervalTooSmall:
            return "The recurrence interval must be at least 1."
        case .occurrenceCountTooSmall:
            return "The occurrence count must be at least 1."
        case .endDateBeforeStart:
            return "The recurrence end date can't be before the event's start date."
        }
    }
}
