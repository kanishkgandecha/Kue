//
//  WidgetContentService.swift
//  Kue
//
//  See docs/07-widget-engine.md "Widget instances vs. event eligibility" (the "Next Up"
//  query) and "Widget lifecycle state machine" (phase thresholds + precomputed timeline).
//  Deliberately free of WidgetKit/SwiftUI/AppIntents so it's testable the same way
//  EventStatusEngine/SchedulingEngine are — via plain KueEvent values and `now`. The
//  KueWidget extension target's TimelineProvider is a thin wrapper around this file; it owns
//  no phase-boundary math of its own.
//

import Foundation

// WidgetLifecyclePhase itself is defined in Shared/Models/WidgetState.swift — reused here
// rather than redeclared, since both this file and the widget extension need the exact
// same phase set docs/07-widget-engine.md describes.

struct WidgetDisplayContent: Equatable {
    var eventTitle: String
    var eventTypeDisplayName: String
    var phase: WidgetLifecyclePhase
    var headline: String
    var subline: String?
}

enum WidgetContentService {
    // MARK: - "Next Up" (docs/07-widget-engine.md "Widget instances vs. event eligibility")

    /// The unconfigured-widget default: soonest `isEnabled` event whose derived status is
    /// upcoming/preparing/tomorrow/today/active — deterministic, ties broken by id so the
    /// same input set always yields the same winner (required by docs/07-widget-engine.md's
    /// determinism and this phase's own "reload dates are deterministic" requirement).
    static func nextUpEvent(from events: [KueEvent], now: Date = .now) -> KueEvent? {
        let eligible: Set<EventStatus> = [.upcoming, .preparing, .tomorrow, .today, .active]
        let candidates = events.filter { event in
            guard event.widgetConfiguration?.isEnabled == true else { return false }
            return eligible.contains(EventStatusEngine.derive(for: event, now: now))
        }
        return candidates.min { lhs, rhs in
            lhs.startDate != rhs.startDate
                ? lhs.startDate < rhs.startDate
                : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Widget lifecycle phase (distinct from EventStatus — see docs/07-widget-engine.md)

    static func calendar(for event: KueEvent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        return calendar
    }

    /// The phase that applies right now — used for the timeline's first entry and for
    /// `snapshot(for:in:)`.
    static func currentPhase(for event: KueEvent, now: Date = .now) -> WidgetLifecyclePhase {
        if event.status == .archived { return .removed }
        if event.isManuallyCompleted || now >= event.effectiveEndDate { return .completed }

        let calendar = calendar(for: event)
        let startOfEventDay = calendar.startOfDay(for: event.startDate)
        if now >= startOfEventDay { return .today }

        let oneDayBefore = calendar.date(byAdding: .day, value: -1, to: startOfEventDay)!
        if now >= oneDayBefore { return .tomorrow }

        if now >= preparationThreshold(for: event, calendar: calendar) { return .preparation }

        return .countdown
    }

    /// "≈3 days out, or when the first KueTask becomes due — whichever is sooner" — the
    /// earlier (chronologically first) of the two candidate dates.
    private static func preparationThreshold(for event: KueEvent, calendar: Calendar) -> Date {
        let threeDaysBefore = calendar.date(byAdding: .day, value: -3, to: event.startDate)!
        let firstTaskDue = event.tasks.map(\.dueDate).min()
        return [threeDaysBefore, firstTaskDue].compactMap { $0 }.min() ?? threeDaysBefore
    }

    /// Every future phase-transition boundary after `now`, ascending — the precomputed
    /// timeline this phase's widget must reload from instead of polling at a fixed interval.
    /// Empty once the event is archived (nothing left to transition to).
    static func transitionPlan(for event: KueEvent, now: Date = .now) -> [(date: Date, phase: WidgetLifecyclePhase)] {
        guard event.status != .archived else { return [] }

        let calendar = calendar(for: event)
        let startOfEventDay = calendar.startOfDay(for: event.startDate)
        let oneDayBefore = calendar.date(byAdding: .day, value: -1, to: startOfEventDay)!
        let preparation = preparationThreshold(for: event, calendar: calendar)

        let candidates: [(Date, WidgetLifecyclePhase)] = [
            (preparation, .preparation),
            (oneDayBefore, .tomorrow),
            (startOfEventDay, .today),
            (event.effectiveEndDate, .completed),
        ]
        return candidates.filter { $0.0 > now }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Display copy (docs/07-widget-engine.md "Widget copy" — deterministic, template-based)

    static func displayContent(for event: KueEvent, phase: WidgetLifecyclePhase, now: Date = .now) -> WidgetDisplayContent {
        let headline: String
        let subline: String?

        switch phase {
        case .countdown:
            headline = event.title
            subline = countdownSubline(for: event, now: now)
        case .preparation:
            headline = event.title
            subline = nextTaskTitle(for: event) ?? "Preparing"
        case .tomorrow:
            headline = "Tomorrow: \(event.title)"
            subline = nextTaskTitle(for: event)
        case .today:
            headline = "Today: \(event.title)"
            subline = event.location
        case .completed:
            headline = event.title
            subline = "Completed"
        case .removed:
            headline = event.title
            subline = "Archived"
        }

        return WidgetDisplayContent(
            eventTitle: event.title,
            eventTypeDisplayName: event.eventType.displayName,
            phase: phase,
            headline: headline,
            subline: subline
        )
    }

    private static func countdownSubline(for event: KueEvent, now: Date) -> String {
        let calendar = calendar(for: event)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: event.startDate)).day ?? 0
        return days == 1 ? "1 day" : "\(max(days, 0)) days"
    }

    private static func nextTaskTitle(for event: KueEvent) -> String? {
        event.tasks.filter { !$0.isCompleted }.min(by: { $0.dueDate < $1.dueDate })?.title
    }
}
