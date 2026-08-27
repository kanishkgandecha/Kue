//
//  HomeTimelineGrouping.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Home's date-sectioned timeline. A pure, presentation-layer grouping of
//  already-computed events (`EventStatusEngine.derive` remains the single source of truth for
//  status; this file only decides which date *section* an event's row renders under) — no
//  change to `EventStatusEngine`/`SchedulingEngine`/persistence.
//
//  Eligibility: events whose derived status is `.completed`/`.cancelled` are never date-
//  sectioned here — they belong to `HomeView`'s separate, compact Completed section, so a
//  long history never proliferates today/tomorrow/dated sections (the requirement's own "do
//  not mix large numbers of completed events into the upcoming timeline"). Everything else
//  (draft/upcoming/preparing/tomorrow/today/active) is grouped by *calendar date, in that
//  event's own pinned `timeZoneIdentifier`* — never the device's current timezone — per
//  requirement: "Timed events must appear under the date that is correct in the event's
//  pinned timezone" / "do not group solely using the device's current timezone." All-day
//  events use the same pinned-timezone calendar for their date components, so they never
//  shift a day because of UTC conversion — the same `Calendar` + explicit `timeZone` pattern
//  `KueEvent.effectiveEndDate` already uses for the identical reason.
//

import Foundation

struct HomeTimelineSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case today
        case tomorrow
        case dated(Date) // start-of-day, in the section's own representative timezone — used only for ordering/identity, never displayed directly
        case later
    }

    let kind: Kind
    let title: String
    let events: [KueEvent]

    var id: String {
        switch kind {
        case .today: return "today"
        case .tomorrow: return "tomorrow"
        case .dated(let date): return "dated-\(date.timeIntervalSinceReferenceDate)"
        case .later: return "later"
        }
    }

    static func == (lhs: HomeTimelineSection, rhs: HomeTimelineSection) -> Bool {
        lhs.id == rhs.id && lhs.events.map(\.id) == rhs.events.map(\.id)
    }
}

enum HomeTimelineGrouping {
    /// Individual (non-"Later") date sections shown before distant events collapse into one
    /// restrained trailing group — requirement: "avoid producing dozens of simultaneously
    /// rendered sections unnecessarily," while every event explicitly created (however
    /// distant — a Pinned-Countdown-style exam a year out) "must remain discoverable and
    /// correctly ordered" inside that trailing group, never dropped.
    static let maximumIndividualDateSections = 5

    /// Requirement: "current and upcoming events" — completed/cancelled events never appear
    /// here (see this file's header); everything else is grouped by calendar date.
    static func timelineEligible(_ event: KueEvent) -> Bool {
        let status = EventStatusEngine.derive(for: event)
        return status != .completed && status != .cancelled
    }

    /// `now` is a parameter (not `.now` read internally) for the same determinism reason
    /// every other date-driven engine in this codebase takes it explicitly
    /// (`EventStatusEngine.derive(for:now:)`, `VoiceInputCoordinator.tick(now:)`) — tests pass
    /// a fixed reference date instead of depending on wall-clock time.
    static func sections(events: [KueEvent], now: Date = .now) -> [HomeTimelineSection] {
        let eligible = events.filter(timelineEligible)
        guard !eligible.isEmpty else { return [] }

        // Group by (event's own pinned-timezone) calendar day.
        var byDay: [Date: [KueEvent]] = [:]
        for event in eligible {
            let day = startOfDay(for: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier)
            byDay[day, default: []].append(event)
        }

        let sortedDays = byDay.keys.sorted()
        var sections: [HomeTimelineSection] = []
        var laterEvents: [KueEvent] = []

        for (index, day) in sortedDays.enumerated() {
            let dayEvents = order(byDay[day] ?? [])
            if index < maximumIndividualDateSections {
                let (kind, title) = kindAndTitle(for: day, now: now)
                sections.append(HomeTimelineSection(kind: kind, title: title, events: dayEvents))
            } else {
                laterEvents.append(contentsOf: dayEvents)
            }
        }

        if !laterEvents.isEmpty {
            // Requirement: "events must remain chronologically grouped inside it" — re-sort
            // the flattened tail by actual start date (not by the per-day ordering above,
            // which only mattered *within* a single day).
            let chronological = laterEvents.sorted { $0.startDate < $1.startDate || ($0.startDate == $1.startDate && $0.id.uuidString < $1.id.uuidString) }
            sections.append(HomeTimelineSection(kind: .later, title: "Later", events: chronological))
        }

        return sections
    }

    // MARK: - Day bucketing (requirement: pinned timezone, DST-safe, no UTC-shift for all-day)

    private static func startOfDay(for date: Date, timeZoneIdentifier: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar.startOfDay(for: date)
    }

    private static func kindAndTitle(for day: Date, now: Date) -> (kind: HomeTimelineSection.Kind, title: String) {
        // "Today"/"Tomorrow" are judged against the *device's* current date only for the
        // section's own start-of-day key comparison — each event was already bucketed into
        // `day` using *its own* pinned timezone above, so this comparison is between two
        // already-pinned-timezone-normalized start-of-day instants, not a re-introduction of
        // device-timezone-only logic.
        let deviceCalendar = Calendar(identifier: .gregorian)
        let todayStart = deviceCalendar.startOfDay(for: now)
        guard let tomorrowStart = deviceCalendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return (.dated(day), formattedTitle(for: day, now: now))
        }
        if day == todayStart { return (.today, "Today") }
        if day == tomorrowStart { return (.tomorrow, "Tomorrow") }
        return (.dated(day), formattedTitle(for: day, now: now))
    }

    /// "Saturday, 30 August" (current year) / "29 November 2026" (a different year) —
    /// requirement's own two example shapes.
    private static func formattedTitle(for day: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let dayYear = calendar.component(.year, from: day)
        let nowYear = calendar.component(.year, from: now)
        if dayYear == nowYear {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: - Within-section ordering (requirement: deterministic, stable across reloads)

    private static func order(_ events: [KueEvent]) -> [KueEvent] {
        events.sorted { lhs, rhs in
            let lhsStatus = EventStatusEngine.derive(for: lhs)
            let rhsStatus = EventStatusEngine.derive(for: rhs)
            if (lhsStatus == .active) != (rhsStatus == .active) { return lhsStatus == .active }
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            if lhs.priority != rhs.priority { return priorityRank(lhs.priority) < priorityRank(rhs.priority) }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}
