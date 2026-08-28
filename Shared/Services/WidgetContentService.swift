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

/// A single task, projected for widget rendering (Timeline/Checklist types) — `id` is the
/// real `KueTask.id`, not a fresh one, so content built from the same tasks compares equal.
struct WidgetTaskSummary: Equatable, Identifiable {
    var id: UUID
    var title: String
    var isCompleted: Bool
    var offsetLabel: String
}

struct WidgetDisplayContent: Equatable {
    /// Phase 9 (M8) addition — the real `KueEvent.id`, needed to construct
    /// `CompleteEventIntent` from the widget's own rendered content rather than requiring a
    /// second store round-trip just to get an identifier the caller already had.
    var eventID: UUID
    var eventTitle: String
    var eventTypeDisplayName: String
    var widgetType: WidgetType
    var phase: WidgetLifecyclePhase
    /// docs/07-widget-engine.md: "urgent is not a lifecycle phase — it's a *treatment*."
    /// Never a case of any enum — always a bool layered on top of `widgetType`/`phase`.
    var isUrgent: Bool
    var headline: String
    var subline: String?
    var tasksCompleted: Int
    var tasksTotal: Int
    /// Up to 4 tasks, soonest-due first — what Timeline/Checklist render; unused by the
    /// other three types.
    var tasks: [WidgetTaskSummary]
    /// Phase 9 (M8) addition — docs/07-widget-engine.md "SnoozeTaskIntent": "If that range is
    /// empty ... the snooze button is hidden, not shown disabled." Event-level (not
    /// per-task): `TaskSnoozeCalculator`'s availability check only depends on
    /// `(event.startDate, now)`, so every task on the same event shares one answer.
    var canSnooze: Bool
}

enum WidgetContentService {
    // MARK: - "Next Up" (docs/07-widget-engine.md "Widget instances vs. event eligibility")

    /// The shared "is this event date/status-wise a live, actionable one right now" check —
    /// both `isEligibleForAutomaticSelection` and `isEligibleForDedicatedSelection` build on
    /// this; it's *not* itself a complete eligibility rule for either caller. Archived is
    /// checked directly on `event.status` (not inferred from the derived status) because a
    /// user can manually archive an event that's still date-wise upcoming, which
    /// `derive(for:)` alone wouldn't catch.
    private static func isDateAndStatusLive(_ event: KueEvent, now: Date) -> Bool {
        // Kue 2.0 Phase 10.1 — docs/25 "F.": `.awaitingOutcome` is deliberately excluded here.
        // A past event with no confirmed outcome must never be selected as "Next Up" or
        // treated as eligible for a fresh Dedicated Countdown pick — it needs a decision, not
        // a countdown.
        let eligible: Set<EventStatus> = [.upcoming, .preparing, .tomorrow, .today, .active]
        guard event.status != .archived else { return false }
        return eligible.contains(EventStatusEngine.derive(for: event, now: now))
    }

    /// docs/22-expanded-and-dedicated-widgets.md "C." — "Next Up"'s own eligibility rule,
    /// unchanged: date/status-live *and* the user hasn't opted this event out of the
    /// automatic widget (`WidgetConfiguration.isEnabled == true`).
    static func isEligibleForAutomaticSelection(_ event: KueEvent, now: Date = .now) -> Bool {
        guard event.widgetConfiguration?.isEnabled == true else { return false }
        return isDateAndStatusLive(event, now: now)
    }

    /// Kue 2.0 Phase 8 correction — the Dedicated Countdown picker's *new-selection*
    /// suggestion/search list. Originally implemented by reusing
    /// `isEligibleForAutomaticSelection` directly; that was wrong — `WidgetConfiguration
    /// .isEnabled` means "opted this event out of the *automatic* widget," which has no
    /// bearing on a user explicitly, one-time picking an event for a Dedicated Countdown
    /// instance (docs/07-widget-engine.md's own `isEnabled` doc: "the user opted this event
    /// out of getting a widget **at all**" is the automatic-widget-era framing this predates
    /// needing to distinguish from). A newly created event isn't excluded here just because
    /// it has no `WidgetConfiguration` yet, or because the user turned the automatic widget
    /// off for it — this picker offers any date/status-live, non-archived event, full stop.
    static func isEligibleForDedicatedSelection(_ event: KueEvent, now: Date = .now) -> Bool {
        isDateAndStatusLive(event, now: now)
    }

    /// The unconfigured-widget default: soonest eligible event — deterministic, ties broken
    /// by id so the same input set always yields the same winner.
    static func nextUpEvent(from events: [KueEvent], now: Date = .now) -> KueEvent? {
        let candidates = events.filter { isEligibleForAutomaticSelection($0, now: now) }
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
    /// `snapshot(for:in:)`. `.removed` is date-driven via
    /// `EventStatusEngine.isPastAutoArchiveWindow`, not solely `event.status == .archived` —
    /// the widget extension never runs the app's sweep itself, so a completed event must
    /// still reach `.removed` on its own once 3 days pass, even if the app hasn't been
    /// foregrounded to persist that.
    static func currentPhase(for event: KueEvent, now: Date = .now) -> WidgetLifecyclePhase {
        if event.status == .archived || EventStatusEngine.isPastAutoArchiveWindow(event, now: now) {
            return .removed
        }
        if event.isManuallyCompleted { return .completed }
        // Kue 2.0 Phase 10.1 — docs/25 "F.": time passing alone never means "Completed" for a
        // widget either. `now >= effectiveEndDate` with no explicit outcome is
        // `.awaitingOutcome`, mirroring `EventStatusEngine.derive` exactly.
        if now >= event.effectiveEndDate { return .awaitingOutcome }

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
    /// Includes `.removed` (the auto-archive threshold), the one boundary that isn't purely
    /// a function of `startDate`/`effectiveEndDate` — see `EventStatusEngine.archiveThreshold`.
    /// Empty once the event is already archived (nothing left to transition to).
    static func transitionPlan(for event: KueEvent, now: Date = .now) -> [(date: Date, phase: WidgetLifecyclePhase)] {
        guard event.status != .archived else { return [] }

        let calendar = calendar(for: event)
        let startOfEventDay = calendar.startOfDay(for: event.startDate)
        let oneDayBefore = calendar.date(byAdding: .day, value: -1, to: startOfEventDay)!
        let preparation = preparationThreshold(for: event, calendar: calendar)

        var candidates: [(Date, WidgetLifecyclePhase)] = [
            (preparation, .preparation),
            (oneDayBefore, .tomorrow),
            (startOfEventDay, .today),
            (event.effectiveEndDate, .awaitingOutcome),
        ]
        // Kue 2.0 Phase 10.1 — docs/25 "C.": `.removed` is only a real future boundary once
        // the event is *already* in a terminal state that actually runs the auto-archive
        // countdown (manually completed, cancelled, or skipped — see
        // `EventStatusEngine.shouldAutoArchive`). An Awaiting Outcome event's archive date is
        // unknowable until the user provides an outcome, so it must never appear as a
        // precomputed transition — precomputing one here would desync from what `reconcile`
        // actually persists, exactly the "assumption that all past events are completed" bug
        // this phase corrects.
        if event.isManuallyCompleted || event.isCancelled || event.isSkipped,
           let archiveDate = EventStatusEngine.archiveThreshold(for: event) {
            candidates.append((archiveDate, .removed))
        }
        return candidates.filter { $0.0 > now }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Urgent treatment (docs/07-widget-engine.md — never a WidgetType case)

    /// V1: Interview and Deadline event types get the urgent treatment, and only within the
    /// `tomorrow`/`today` phases; Exam, Trip, and Generic never do.
    static func isUrgentTreatment(eventType: EventType, phase: WidgetLifecyclePhase) -> Bool {
        guard phase == .tomorrow || phase == .today else { return false }
        return eventType == .interview || eventType == .deadline
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
            // docs/09-screens-and-ux.md "Widget configuration": `showLocation` is a real,
            // user-editable toggle (Event Detail's Widget tab) — genuine V1 gap found during
            // the Phase 10 audit, it was persisted but never actually read here.
            subline = (event.widgetConfiguration?.showLocation ?? true) ? event.location : nil
        case .awaitingOutcome:
            headline = event.title
            // docs/25 "A." — the one consistent user-facing label chosen for this status.
            subline = "Needs Review"
        case .completed:
            headline = event.title
            subline = "Completed"
        case .removed:
            headline = event.title
            subline = "Archived"
        }

        let sortedTasks = event.tasks.sorted { $0.dueDate < $1.dueDate }

        return WidgetDisplayContent(
            eventID: event.id,
            eventTitle: event.title,
            eventTypeDisplayName: event.eventType.displayName,
            widgetType: event.widgetConfiguration?.widgetType ?? .countdown,
            phase: phase,
            isUrgent: isUrgentTreatment(eventType: event.eventType, phase: phase),
            headline: headline,
            subline: subline,
            tasksCompleted: event.tasks.count(where: { $0.isCompleted }),
            tasksTotal: event.tasks.count,
            tasks: sortedTasks.prefix(4).map {
                WidgetTaskSummary(id: $0.id, title: $0.title, isCompleted: $0.isCompleted, offsetLabel: $0.offsetLabel)
            },
            canSnooze: TaskSnoozeCalculator.isSnoozeAvailable(eventStartDate: event.startDate, now: now)
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
