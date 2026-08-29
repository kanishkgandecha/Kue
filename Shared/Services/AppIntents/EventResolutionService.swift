//
//  EventResolutionService.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "D." — the one deterministic
//  event-lookup policy every Siri/Shortcuts/Spotlight/Control-Center entry point shares. Pure
//  (SwiftData-free — takes an already-fetched `[KueEvent]`, mirrors
//  `EventListQueryEngine`/`WidgetContentService`'s own "plan first, touch the model graph
//  second" split) so it's testable with in-memory fixtures and reusable from `Kue/AppIntents/`
//  (main app), `KueWidget/` (Control Widgets), and `KueTests` alike. Reuses
//  `EventSearchNormalizer` (Phase 2) for case-/diacritic-insensitive title comparison and
//  `WidgetContentService.nextUpEvent` (Phase 4/8/9) for "next event" — this file adds no
//  second normalization or eligibility rule of its own.
//

import Foundation

/// The outcome of any lookup that could match more than one event — never silently picks a
/// "first" match. Requirement D: "Never mutate the first fuzzy match silently."
enum EventResolution: Equatable {
    case found(KueEvent)
    /// More than one event matches equally well — the caller must present a disambiguation
    /// (App Intent parameter disambiguation, or an explanatory Siri response) rather than
    /// guessing. Capped at a small preview count by the caller, never used to mutate.
    case ambiguous([KueEvent])
    case notFound

    static func == (lhs: EventResolution, rhs: EventResolution) -> Bool {
        switch (lhs, rhs) {
        case (.found(let l), .found(let r)): return l.id == r.id
        case (.ambiguous(let l), .ambiguous(let r)): return l.map(\.id) == r.map(\.id)
        case (.notFound, .notFound): return true
        default: return false
        }
    }
}

enum EventResolutionService {
    /// Exact id — the only lookup that's ever unambiguous by construction. Used when a caller
    /// already has a stable identifier (a widget button, a Shortcuts variable piped from
    /// `FindEventsIntent`, a Spotlight/deep-link tap).
    static func resolve(id: UUID, in events: [KueEvent]) -> EventResolution {
        events.first { $0.id == id }.map(EventResolution.found) ?? .notFound
    }

    /// Exact normalized-title match, then (only if no exact match exists) a unique
    /// case-/diacritic-insensitive substring match — the same `EventSearchNormalizer`
    /// (Phase 2) every other search surface in Kue uses, so Siri's notion of "which event"
    /// never diverges from what Search itself would find. Multiple equally-good matches never
    /// pick one silently.
    static func resolve(title: String, in events: [KueEvent]) -> EventResolution {
        let normalizedQuery = EventSearchNormalizer.normalize(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return .notFound }

        let exact = events.filter { EventSearchNormalizer.normalize($0.title) == normalizedQuery }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(stableOrder(exact)) }

        let partial = events.filter { EventSearchNormalizer.normalize($0.title).contains(normalizedQuery) }
        switch partial.count {
        case 0: return .notFound
        case 1: return .found(partial[0])
        default: return .ambiguous(stableOrder(partial))
        }
    }

    /// Requirement D: "reuse the existing deterministic eligibility/order policy" — this is
    /// deliberately just a pass-through to `WidgetContentService.nextUpEvent`, not a
    /// re-derived rule, so Siri's "what's next" can never disagree with Home/the widget's own
    /// "Next Up" pick. Never selects a Dedicated Countdown or Live Activity event — those stay
    /// entirely separate policies (docs/22 "C.", docs/23 "C.").
    static func nextEvent(in events: [KueEvent], now: Date = .now) -> KueEvent? {
        WidgetContentService.nextUpEvent(from: events, now: now)
    }

    /// Today's events, in the event's own pinned timezone (same day-bucketing
    /// `HomeTimelineGrouping`/`WidgetContentService` already use), current/non-archived only,
    /// stable date order.
    static func todaysEvents(in events: [KueEvent], now: Date = .now) -> [KueEvent] {
        let deviceToday = Calendar(identifier: .gregorian).startOfDay(for: now)
        let matches = events.filter { event in
            guard event.status != .archived else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
            return calendar.startOfDay(for: event.startDate) == deviceToday
        }
        return EventListQueryEngine.sorted(matches, by: .date)
    }

    /// Upcoming, current (non-archived, non-terminal) events — the same "date/status-live" set
    /// `WidgetContentService.isEligibleForAutomaticSelection`'s underlying check already
    /// defines minus the widget-opt-out gate (a Siri/Shortcuts query has no bearing on whether
    /// an event opted out of the *widget*), stable date order.
    static func upcomingEvents(in events: [KueEvent], now: Date = .now) -> [KueEvent] {
        let eligible: Set<EventStatus> = [.upcoming, .preparing, .tomorrow, .today, .active]
        let matches = events.filter { event in
            guard event.status != .archived else { return false }
            return eligible.contains(EventStatusEngine.derive(for: event, now: now))
        }
        return EventListQueryEngine.sorted(matches, by: .date)
    }

    /// Filters by event type only — used by `FindEventsIntent`'s optional type filter.
    static func filter(_ events: [KueEvent], type: EventType) -> [KueEvent] {
        events.filter { $0.eventType == type }
    }

    /// A deterministic, capped preview list for a disambiguation response — never more than
    /// `limit` titles read aloud/shown, always the same stable order every other list surface
    /// uses (date, then normalized title, then id).
    static func stableOrder(_ events: [KueEvent], limit: Int? = nil) -> [KueEvent] {
        let ordered = EventListQueryEngine.sorted(events, by: .date)
        guard let limit else { return ordered }
        return Array(ordered.prefix(limit))
    }
}
