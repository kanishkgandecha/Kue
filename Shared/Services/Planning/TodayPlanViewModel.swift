//
//  TodayPlanViewModel.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36. The one place that turns the live model graph into a
//  `TodayPlan`: fetches events, takes the cheap `@MainActor` snapshot
//  (`PlanningSnapshotBuilder`), reads Calendar busy intervals through the existing
//  `CalendarProviding` seam when the preference allows it, reads local statistics through the
//  existing `ProfileStatisticsEngine` when that preference allows it, then hands everything to
//  `SmartPlanningEngine.makePlan` on a detached background task — requirement M: "keep
//  expensive computation off the main actor... avoid recalculating the full plan on every
//  SwiftUI body evaluation." `refresh()` is only ever called explicitly (on appear, after an
//  accept/dismiss/snooze, on pull-to-refresh) — nothing here recomputes on every render;
//  `@Observable` only republishes when `plan` itself actually changes.
//
//  Shared by both `TodayPlanView` (iOS) and `MacTodayPlanView` (macOS) — the one business-
//  logic surface behind two platform-native presentations (requirement D).
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class TodayPlanViewModel {
    private(set) var plan: TodayPlan?
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// How far ahead to ask Calendar for busy intervals — generous enough for every category's
    /// own lookahead (`PlanningIntensity.riskLeadDays` tops out at 7) plus slack for focus-
    /// block placement's own week-long search ceiling.
    private static let calendarLookaheadDays = 14

    func refresh(context: ModelContext, calendarProvider: CalendarProviding, now: Date = .now) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let (eventSnapshots, taskSnapshots) = PlanningSnapshotBuilder.snapshot(events: events, now: now)
        let preferences = SmartPlanningPreferences.current

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current

        var busyIntervals: [DateInterval]?
        if preferences.considerCalendarAvailability, calendarProvider.authorizationState().canReadEvents,
           let horizon = deviceCalendar.date(byAdding: .day, value: Self.calendarLookaheadDays, to: now) {
            busyIntervals = calendarProvider.fetchEvents(from: now, to: horizon)
                .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        }

        let statistics = preferences.useLocalStatistics
            ? ProfileStatisticsEngine.compute(events: events, now: now, calendar: deviceCalendar)
            : nil

        let suppressed = RecommendationDismissalStore.activeSuppressedIDs(now: now)

        let input = SmartPlanningEngineInput(
            now: now, calendar: deviceCalendar, preferences: preferences, events: eventSnapshots,
            tasks: taskSnapshots, busyIntervals: busyIntervals, statistics: statistics, suppressedIDs: suppressed
        )

        // The actual scoring pass — off the main actor, per requirement M. `input` is fully
        // `Sendable` value data by this point, so this detach is safe.
        let computed = await Task.detached(priority: .userInitiated) {
            SmartPlanningEngine.makePlan(input)
        }.value

        self.plan = computed
    }
}
