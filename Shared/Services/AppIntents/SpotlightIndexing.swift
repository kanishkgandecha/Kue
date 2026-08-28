//
//  SpotlightIndexing.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "G." — the protocol + System + Fake DI
//  seam for Core Spotlight, same shape every other Kue subsystem uses
//  (`LiveActivityManaging`/`CalendarProviding`/`OCRTextRecognizing`). `SpotlightEventPayload`
//  is the pure, privacy-safe field list actually indexed — deliberately narrower than
//  `KueEvent` itself, built once here so every caller (System indexer, Fake, tests) reads the
//  exact same redaction rule instead of each re-deciding which fields are safe.
//
//  Privacy: title, event type, effective date, and a status label only. Never notes, OCR
//  text, voice transcripts, Calendar source metadata, hidden task titles, or location — see
//  docs/24 "Privacy matrix" for the full reasoning.
//

import Foundation

/// Lives in `Shared/` (reachable by `Kue/AppIntents/` and `KueTests` alike) even though only
/// the main app ever actually calls a real indexer — no other target performs Spotlight work.
struct SpotlightEventPayload: Equatable, Sendable {
    var eventID: UUID
    var title: String
    var eventTypeDisplayName: String
    var effectiveDate: Date
    var isAllDay: Bool
    /// A short, privacy-safe status word ("Upcoming," "Today," "Completed," "Cancelled," …) —
    /// never the raw persisted `EventStatus` rawValue, so this stays a stable, presentable
    /// string even if `EventStatus` itself gains/renames cases later.
    var statusLabel: String
}

enum SpotlightEventPayloadBuilder {
    /// Archived events are still indexed (findable by exact title — "what happened to my old
    /// trip to Boston") but read as "Archived," matching the deep-link target's own honest
    /// state once opened; never silently excluded (that's a stale-index bug, not privacy).
    static func payload(for event: KueEvent, now: Date = .now) -> SpotlightEventPayload {
        let status = event.status == .archived ? EventStatus.archived : EventStatusEngine.derive(for: event, now: now)
        return SpotlightEventPayload(
            eventID: event.id,
            title: event.title,
            eventTypeDisplayName: event.eventType.displayName,
            effectiveDate: event.startDate,
            isAllDay: event.isAllDay,
            statusLabel: statusLabel(for: status)
        )
    }

    static func statusLabel(for status: EventStatus) -> String {
        switch status {
        case .draft: return "Draft"
        case .upcoming: return "Upcoming"
        case .preparing: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .active: return "Active"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .archived: return "Archived"
        }
    }
}

protocol SpotlightIndexing: Sendable {
    /// Indexes (or re-indexes, `isUpdate = true`) one or more events — always the *current*
    /// full payload, never a partial patch, so a single index call is always safely repeatable.
    func index(_ payloads: [SpotlightEventPayload]) async
    /// Removes specific events by id — used on delete, and (belt-and-suspenders) whenever a
    /// reconciliation pass finds a payload id with no matching `KueEvent` any more.
    func remove(eventIDs: [UUID]) async
    /// Removes every Kue-indexed item — used by "Delete Everything" (`PrivacyActions`) and the
    /// Settings "Remove Spotlight Entries" control.
    func removeAll() async
}
