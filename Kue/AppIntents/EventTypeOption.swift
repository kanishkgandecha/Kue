//
//  EventTypeOption.swift
//  Kue
//
//  A Shortcuts-facing `AppEnum` mirror of `EventType` (Shared/Models/KueEvent.swift) — kept as
//  a small app-only wrapper rather than adding `AppEntities`/`AppEnum` conformance to the
//  shared model type itself, so `Shared/` (compiled into `KueWidget` and `KueShare` too) never
//  needs an `AppIntents` import for a concern only Siri/Shortcuts-facing intents have.
//  `AppEnum` (unlike `AppEntity`) is a plain, closed-set, compile-time-only value type with no
//  runtime entity-registry lookup, so it carries none of the Phase 8 `AppEntity` registration
//  risk (docs/24 "E.").
//

import AppIntents

enum EventTypeOption: String, AppEnum {
    case generic, deadline, exam, interview, trip

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Event Type"

    static var caseDisplayRepresentations: [EventTypeOption: DisplayRepresentation] = [
        .generic: "Generic",
        .deadline: "Deadline",
        .exam: "Exam",
        .interview: "Interview",
        .trip: "Trip",
    ]

    var eventType: EventType {
        switch self {
        case .generic: return .generic
        case .deadline: return .deadline
        case .exam: return .exam
        case .interview: return .interview
        case .trip: return .trip
        }
    }

    init(_ eventType: EventType) {
        switch eventType {
        case .generic: self = .generic
        case .deadline: self = .deadline
        case .exam: self = .exam
        case .interview: self = .interview
        case .trip: self = .trip
        }
    }
}

/// The subset of `EventType` that Templates offers (docs/09-screens-and-ux.md — "Interview,
/// Exam, Trip, Deadline (built-in only)"), mirroring `TemplatesView.templateTypes` exactly so
/// "Create Event from a Template" can never offer a type Templates itself doesn't.
enum EventTemplateOption: String, AppEnum {
    case interview, exam, trip, deadline

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Template"

    static var caseDisplayRepresentations: [EventTemplateOption: DisplayRepresentation] = [
        .interview: "Interview",
        .exam: "Exam",
        .trip: "Trip",
        .deadline: "Deadline",
    ]

    var eventType: EventType {
        switch self {
        case .interview: return .interview
        case .exam: return .exam
        case .trip: return .trip
        case .deadline: return .deadline
        }
    }
}
