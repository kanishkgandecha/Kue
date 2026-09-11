//
//  ProfileStatisticsEngine.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Statistics definitions." Pure, deterministic — takes an already-
//  fetched `[KueEvent]` plus `now`/`calendar`, returns one plain, `Equatable` `ProfileStatistics`
//  value. Never uploaded to Supabase (requirement G: "computed from the existing local
//  SwiftData store, not uploaded"); this file has no networking, no `AccountProviding`
//  dependency at all — the Profile screen simply reads both a `ProfileStatistics` and an
//  `AccountState` side by side.
//
//  Reuses `EventStatusEngine.derive(for:now:)` for every status decision rather than
//  re-deriving status logic a second time — the same "one definition of truth" precedent
//  every other status-reading feature in this codebase (Home, widgets, notifications) already
//  follows.
//
//  Deliberately excludes anything resembling a productivity "score" or insight the data can't
//  actually support (requirement G) — every field here is a plain, honest count, rate, or
//  nearest-fact, never a weighted or normalized index.
//

import Foundation

nonisolated struct ProfileStatistics: Equatable {
    var totalActiveEvents: Int
    var completedEvents: Int
    var eventsNeedingReview: Int
    var upcomingEvents: Int
    var completedTasks: Int
    var pendingTasks: Int
    /// `nil` when there are zero relevant tasks to compute a rate from — division by zero is
    /// never silently coerced to 0% or 100%.
    var completionRate: Double?
    var countsByEventType: [EventType: Int]
    var nearestUpcomingEvent: UpcomingEventSummary?
    /// `nil` when there is no completed-or-cancelled history yet to compute a streak from at
    /// all (a genuinely new account) — `0` means there *is* history, but the most recent
    /// resolved event wasn't a completion. See `preparationStreak(events:now:)`'s own header
    /// for the exact definition.
    var preparationStreak: Int?

    static let empty = ProfileStatistics(
        totalActiveEvents: 0, completedEvents: 0, eventsNeedingReview: 0, upcomingEvents: 0,
        completedTasks: 0, pendingTasks: 0, completionRate: nil, countsByEventType: [:],
        nearestUpcomingEvent: nil, preparationStreak: nil
    )
}

nonisolated struct UpcomingEventSummary: Equatable {
    var id: UUID
    var title: String
    var startDate: Date
    var eventType: EventType
    var isToday: Bool
}

nonisolated enum ProfileStatisticsEngine {
    /// Terminal-and-resolved statuses that never count toward "active"/"upcoming" — the same
    /// three-way split `EventStatusEngine`'s own callers already use everywhere else.
    private static let terminalStatuses: Set<EventStatus> = [.completed, .cancelled, .archived]
    private static let upcomingStatuses: Set<EventStatus> = [.upcoming, .tomorrow, .today, .preparing]

    static func compute(events: [KueEvent], now: Date = .now, calendar: Calendar = .current) -> ProfileStatistics {
        guard !events.isEmpty else { return .empty }

        var completedEvents = 0
        var eventsNeedingReview = 0
        var upcomingEvents = 0
        var totalActiveEvents = 0
        var completedTasks = 0
        var pendingTasks = 0
        var countsByEventType: [EventType: Int] = [:]
        var nearestUpcoming: KueEvent?

        for event in events {
            countsByEventType[event.eventType, default: 0] += 1
            let status = EventStatusEngine.derive(for: event, now: now)

            if !terminalStatuses.contains(status) { totalActiveEvents += 1 }
            switch status {
            case .completed: completedEvents += 1
            case .awaitingOutcome: eventsNeedingReview += 1
            default: break
            }
            if upcomingStatuses.contains(status) { upcomingEvents += 1 }

            // A cancelled event's tasks are moot, not "pending" in any real sense — excluded
            // explicitly (requirement G: "handle... cancelled... events explicitly").
            guard !event.isCancelled else { continue }
            for task in event.tasks {
                if task.isCompleted { completedTasks += 1 } else { pendingTasks += 1 }
            }

            // "Nearest upcoming": not yet resolved (not completed/cancelled/archived/awaiting
            // review) and starts at or after `now` — the earliest such `startDate` wins.
            guard !terminalStatuses.contains(status), status != .awaitingOutcome, event.startDate >= now else { continue }
            if nearestUpcoming == nil || event.startDate < nearestUpcoming!.startDate {
                nearestUpcoming = event
            }
        }

        let completionRate: Double? = (completedTasks + pendingTasks) > 0
            ? Double(completedTasks) / Double(completedTasks + pendingTasks)
            : nil

        let nearestSummary = nearestUpcoming.map {
            UpcomingEventSummary(id: $0.id, title: $0.title, startDate: $0.startDate, eventType: $0.eventType, isToday: calendar.isDate($0.startDate, inSameDayAs: now))
        }

        return ProfileStatistics(
            totalActiveEvents: totalActiveEvents, completedEvents: completedEvents, eventsNeedingReview: eventsNeedingReview,
            upcomingEvents: upcomingEvents, completedTasks: completedTasks, pendingTasks: pendingTasks,
            completionRate: completionRate, countsByEventType: countsByEventType,
            nearestUpcomingEvent: nearestSummary, preparationStreak: preparationStreak(events: events, now: now)
        )
    }

    /// **Definition** (deliberately narrow and deterministic, not a subjective "quality"
    /// score — requirement G: "do not create manipulative scores"): among every non-cancelled
    /// event whose derived status is `.completed` or that is `.cancelled` (i.e. every event
    /// that has actually *resolved*, one way or the other, excluding anything still upcoming
    /// or awaiting review), ordered by `startDate` descending (most recent first), count how
    /// many in a row — starting from the most recent — were manually completed before hitting
    /// the first cancelled one. `nil` when there is no resolved history at all yet; `0` when
    /// the single most recent resolved event was a cancellation.
    private static func preparationStreak(events: [KueEvent], now: Date) -> Int? {
        let resolved = events
            .filter { $0.isCancelled || EventStatusEngine.derive(for: $0, now: now) == .completed }
            .sorted { $0.startDate > $1.startDate }
        guard !resolved.isEmpty else { return nil }

        var streak = 0
        for event in resolved {
            if event.isCancelled { break }
            streak += 1
        }
        return streak
    }
}
