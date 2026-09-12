//
//  ProfileStatisticsEngine.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Statistics definitions." Extended Kue 3.0 Phase 6 — docs/34
//  "Metric definitions." Pure, deterministic — takes an already-fetched `[KueEvent]` plus
//  `now`/`calendar`, returns one plain, `Equatable` `ProfileStatistics` value: the one
//  immutable snapshot both the iPhone/Mac dashboards render from *and* the source
//  `StatisticsAggregatePayload.make(from:)` (Shared/Services/Statistics/) derives its own,
//  much narrower, upload payload from — never a second, competing computation. This file
//  itself never uploads or knows about Supabase at all (requirement A: "computed from the
//  existing local SwiftData store, not uploaded"; requirement C: "one immutable snapshot...
//  suitable for deterministic UI rendering and optional aggregate upload").
//
//  Reuses `EventStatusEngine.derive(for:now:)` for every status decision rather than
//  re-deriving status logic a second time — the same "one definition of truth" precedent
//  every other status-reading feature in this codebase (Home, widgets, notifications) already
//  follows.
//
//  Deliberately excludes anything resembling a productivity "score," ranking, or judgmental
//  language (requirement C) — every field here is a plain, honest count, rate, or nearest-fact,
//  never a weighted or normalized index. "Not enough data" is always `nil`, never an invented
//  `0`/`100%` standing in for a real value the data can't yet support.
//
//  Phase 6 audit of the Phase 4 version of this file (docs/34 "B."): cancelled and skipped
//  events were previously conflated (both simply excluded from active/upcoming, `isSkipped`
//  was never read at all) — fixed below with `cancelledEvents`/`skippedEvents` counted
//  separately, since the model's own `isCancelled`/`isSkipped` are documented as mutually
//  exclusive. `terminalStatuses` included `.archived`, which `EventStatusEngine.derive` can
//  never actually produce (`reconcile(_:now:)`'s own header: "never returns .draft or
//  .archived" from `derive` — those come only from the separately-persisted `event.status`
//  after a reconciliation sweep) — the branch was harmless dead weight (an archived event's
//  underlying `isCancelled`/`isManuallyCompleted` still resolve it correctly to `.cancelled`/
//  `.completed` here) but is called out here rather than silently left unexplained. No
//  passing-date-as-completion defect was found: `.awaitingOutcome` already gates every
//  completion path on an explicit user action (docs/25), and this file never treats it as
//  resolved.
//

import Foundation

nonisolated struct ProfileStatistics: Equatable {
    var totalActiveEvents: Int
    var completedEvents: Int
    /// Reported separately from `cancelledEvents` — Phase 6 correction. `isCancelled`/
    /// `isSkipped` are documented as mutually exclusive on `KueEvent`, so every event lands in
    /// exactly one of these two counts (or neither, if unresolved).
    var cancelledEvents: Int
    var skippedEvents: Int
    var eventsNeedingReview: Int
    var upcomingEvents: Int
    /// Non-terminal, non-awaiting-review events whose start falls within the next 7/30
    /// calendar days (inclusive of today, exclusive of day 7/30's end) — see
    /// `isWithinForwardWindow(_:days:)` for the exact day-boundary arithmetic.
    var upcoming7Days: Int
    var upcoming30Days: Int
    var completedTasks: Int
    var pendingTasks: Int
    /// `nil` when there are zero relevant tasks to compute a rate from — division by zero is
    /// never silently coerced to 0% or 100%.
    var completionRate: Double?
    var countsByEventType: [EventType: Int]
    /// Phase 6 addition — requirement C: "completion totals grouped by event type," distinct
    /// from `countsByEventType` (every event regardless of status) above.
    var completedCountsByEventType: [EventType: Int]
    /// Phase 6 addition — requirement C: "current preparation workload." Pending (incomplete)
    /// tasks, on a non-cancelled event, due within the next 7 days *or already overdue* —
    /// deliberately narrower than the blanket `pendingTasks` total above, which counts every
    /// incomplete task regardless of how soon its own due date actually is. Phase 6 audit
    /// found and corrected a real defect in an earlier draft of this same field: it was
    /// defined around `EventStatus.preparing`, which `EventStatusEngine.derive(for:)` can
    /// never actually produce (that file's own header: a documented Kue 2.0 spec gap, "folding
    /// it into `.upcoming` until real per-type templates exist") — that version would have
    /// always read `0` in production. Redefined around each task's own `dueDate` instead,
    /// which is always reachable.
    var preparationWorkload: Int
    var nearestUpcomingEvent: UpcomingEventSummary?
    /// `nil` when there is no completed-or-cancelled-or-skipped history yet to compute a streak
    /// from at all (a genuinely new account) — `0` means there *is* history, but the most
    /// recent resolved event wasn't a completion. See `completionStreaks(events:now:)`'s own
    /// header for the exact, single shared definition both this and `longestCompletionStreak`
    /// are computed from.
    var currentCompletionStreak: Int?
    /// Phase 6 addition — the longest run of consecutive completions found *anywhere* in the
    /// resolved history, not just the most recent run. Always `>= currentCompletionStreak`
    /// whenever both are non-`nil` (the current streak is, by definition, one of the runs
    /// scanned). Same `nil`/`0` honesty as `currentCompletionStreak`.
    var longestCompletionStreak: Int?
    /// Phase 6 addition — requirement C: "average task completion lead time when enough data
    /// exists." Hours between a task's `completedAt` and its own `dueDate` (`dueDate -
    /// completedAt`, so a positive value means tasks tend to be finished *before* they were
    /// due, negative means *after*) — never rounded to hide a genuinely negative average.
    /// `nil` below `minimumTasksForLeadTime` qualifying samples (requirement C: "an honest
    /// 'not enough data' state instead of invented values"), not a misleading `0`.
    var averageTaskCompletionLeadTimeHours: Double?
    /// Phase 6 addition — requirement C: "weekly activity for a bounded recent period." Exactly
    /// `weeklyActivityWeekCount` buckets (oldest first), one per calendar week, covering
    /// completions only — never a raw event/task content dump. Empty exactly when `events` was
    /// empty to begin with (see `.empty` below); otherwise always the full bounded window, with
    /// genuinely-zero weeks included rather than omitted, so a chart's x-axis stays stable.
    var weeklyActivity: [WeeklyActivityBucket]

    static let empty = ProfileStatistics(
        totalActiveEvents: 0, completedEvents: 0, cancelledEvents: 0, skippedEvents: 0,
        eventsNeedingReview: 0, upcomingEvents: 0, upcoming7Days: 0, upcoming30Days: 0,
        completedTasks: 0, pendingTasks: 0, completionRate: nil, countsByEventType: [:],
        completedCountsByEventType: [:], preparationWorkload: 0, nearestUpcomingEvent: nil,
        currentCompletionStreak: nil, longestCompletionStreak: nil,
        averageTaskCompletionLeadTimeHours: nil, weeklyActivity: []
    )
}

nonisolated struct UpcomingEventSummary: Equatable {
    var id: UUID
    var title: String
    var startDate: Date
    var eventType: EventType
    var isToday: Bool
}

/// One calendar week's completion activity — `weekStart` is that week's first instant
/// (`calendar.dateInterval(of: .weekOfYear, for:)`'s own start), never a raw event/task title
/// or identifier; this shape is deliberately as safe to render as it would be to serialize.
nonisolated struct WeeklyActivityBucket: Equatable, Identifiable {
    var id: Date { weekStart }
    var weekStart: Date
    var completedEventCount: Int
    var completedTaskCount: Int
}

nonisolated enum ProfileStatisticsEngine {
    /// Terminal-and-resolved statuses that never count toward "active"/"upcoming" — the same
    /// three-way split `EventStatusEngine`'s own callers already use everywhere else.
    /// `.archived` is included for documentation/defensiveness only — see this file's own
    /// header: `EventStatusEngine.derive` never actually produces it.
    private static let terminalStatuses: Set<EventStatus> = [.completed, .cancelled, .archived]
    private static let upcomingStatuses: Set<EventStatus> = [.upcoming, .tomorrow, .today, .preparing]
    /// Preparation-workload horizon — a pending task due before this many days from now (or
    /// already overdue) counts toward `preparationWorkload`.
    private static let preparationWorkloadDays = 7
    /// Bounded recent period for `weeklyActivity` — requirement C: "a bounded recent period,"
    /// never the account's whole history.
    private static let weeklyActivityWeekCount = 8
    /// Requirement C: "an honest 'not enough data' state instead of invented values" — below
    /// this many qualifying completed tasks, `averageTaskCompletionLeadTimeHours` is `nil`
    /// rather than an average of one or two samples presented with false confidence.
    private static let minimumTasksForLeadTime = 3

    static func compute(events: [KueEvent], now: Date = .now, calendar: Calendar = .current) -> ProfileStatistics {
        guard !events.isEmpty else { return .empty }

        var completedEvents = 0
        var cancelledEvents = 0
        var skippedEvents = 0
        var eventsNeedingReview = 0
        var upcomingEvents = 0
        var upcoming7Days = 0
        var upcoming30Days = 0
        var totalActiveEvents = 0
        var completedTasks = 0
        var pendingTasks = 0
        var preparationWorkload = 0
        var countsByEventType: [EventType: Int] = [:]
        var completedCountsByEventType: [EventType: Int] = [:]
        var nearestUpcoming: KueEvent?
        var leadTimesHours: [Double] = []

        for event in events {
            countsByEventType[event.eventType, default: 0] += 1
            let status = EventStatusEngine.derive(for: event, now: now)

            if !terminalStatuses.contains(status) { totalActiveEvents += 1 }
            switch status {
            case .completed:
                completedEvents += 1
                completedCountsByEventType[event.eventType, default: 0] += 1
            case .awaitingOutcome:
                eventsNeedingReview += 1
            default:
                break
            }
            // Mutually exclusive on the model itself (KueEvent.isSkipped's own header) — an
            // event lands in at most one of these two counts.
            if event.isSkipped { skippedEvents += 1 }
            else if event.isCancelled { cancelledEvents += 1 }

            if upcomingStatuses.contains(status) { upcomingEvents += 1 }
            if !terminalStatuses.contains(status), status != .awaitingOutcome {
                if isWithinForwardWindow(event.startDate, of: now, days: 7, calendar: calendar) { upcoming7Days += 1 }
                if isWithinForwardWindow(event.startDate, of: now, days: 30, calendar: calendar) { upcoming30Days += 1 }
            }

            // A cancelled (or skipped, which derives as cancelled) event's tasks are moot, not
            // "pending" in any real sense — excluded explicitly (requirement B: "handle...
            // cancelled... events explicitly").
            guard !event.isCancelled else { continue }
            for task in event.tasks {
                if task.isCompleted {
                    completedTasks += 1
                    if let completedAt = task.completedAt {
                        leadTimesHours.append(task.dueDate.timeIntervalSince(completedAt) / 3600)
                    }
                } else {
                    pendingTasks += 1
                    if isDueWithinPreparationWindow(task.dueDate, of: now, calendar: calendar) { preparationWorkload += 1 }
                }
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
        let averageLeadTime: Double? = leadTimesHours.count >= minimumTasksForLeadTime
            ? leadTimesHours.reduce(0, +) / Double(leadTimesHours.count)
            : nil

        let nearestSummary = nearestUpcoming.map {
            UpcomingEventSummary(id: $0.id, title: $0.title, startDate: $0.startDate, eventType: $0.eventType, isToday: calendar.isDate($0.startDate, inSameDayAs: now))
        }

        let streaks = completionStreaks(events: events, now: now)

        return ProfileStatistics(
            totalActiveEvents: totalActiveEvents, completedEvents: completedEvents,
            cancelledEvents: cancelledEvents, skippedEvents: skippedEvents,
            eventsNeedingReview: eventsNeedingReview, upcomingEvents: upcomingEvents,
            upcoming7Days: upcoming7Days, upcoming30Days: upcoming30Days,
            completedTasks: completedTasks, pendingTasks: pendingTasks,
            completionRate: completionRate, countsByEventType: countsByEventType,
            completedCountsByEventType: completedCountsByEventType, preparationWorkload: preparationWorkload,
            nearestUpcomingEvent: nearestSummary,
            currentCompletionStreak: streaks.current, longestCompletionStreak: streaks.longest,
            averageTaskCompletionLeadTimeHours: averageLeadTime,
            weeklyActivity: weeklyActivity(events: events, now: now, calendar: calendar)
        )
    }

    /// True when `date`'s calendar day falls in `[today, today + days)` — `today` itself
    /// counts (an event starting later today is still "within the next 7 days"), the boundary
    /// `days` days out does not (matches `EventStatusEngine.derive`'s own day-boundary
    /// arithmetic style rather than a raw, timezone-fragile `TimeInterval` comparison).
    private static func isWithinForwardWindow(_ date: Date, of now: Date, days: Int, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: days, to: today) else { return false }
        return date >= today && date < horizon
    }

    /// True when `date` is already in the past relative to `now`, or falls within the next
    /// `preparationWorkloadDays` calendar days — an overdue task is, if anything, *more*
    /// urgent than one due later this week, so it is deliberately included with no lower bound.
    private static func isDueWithinPreparationWindow(_ date: Date, of now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: preparationWorkloadDays, to: today) else { return false }
        return date < horizon
    }

    /// **Definition** (deliberately narrow and deterministic, not a subjective "quality"
    /// score — requirement C: "do not create manipulative scores"): among every non-cancelled,
    /// non-skipped event whose derived status is `.completed`, or that is cancelled/skipped
    /// (i.e. every event that has actually *resolved*, one way or the other, excluding
    /// anything still upcoming or awaiting review), ordered by `startDate` descending (most
    /// recent first): **current streak** is how many in a row — starting from the most recent
    /// — were completions, stopping at the first cancelled/skipped one. **Longest streak** is
    /// the longest such run found anywhere in that same ordered list, not only the most recent
    /// one. Both `nil` when there is no resolved history at all yet; both `0` when the pattern
    /// never produces a run of completions (e.g. the single most recent resolved event was a
    /// cancellation).
    private static func completionStreaks(events: [KueEvent], now: Date) -> (current: Int?, longest: Int?) {
        let resolved = events
            .filter { $0.isCancelled || $0.isSkipped || EventStatusEngine.derive(for: $0, now: now) == .completed }
            .sorted { $0.startDate > $1.startDate }
        guard !resolved.isEmpty else { return (nil, nil) }

        var current = 0
        var currentStillCounting = true
        var longest = 0
        var runningRun = 0
        for event in resolved {
            let isCompletion = !event.isCancelled && !event.isSkipped
            if isCompletion {
                runningRun += 1
                longest = max(longest, runningRun)
                if currentStillCounting { current += 1 }
            } else {
                runningRun = 0
                currentStillCounting = false
            }
        }
        return (current, longest)
    }

    /// Requirement C: "weekly activity for a bounded recent period." Buckets completions —
    /// never raw event/task titles — into the most recent `weeklyActivityWeekCount` calendar
    /// weeks (oldest first), each keyed by `calendar`'s own week start, so the result is fully
    /// deterministic for a fixed `now`/`calendar` pair. A completed event with no
    /// `manuallyCompletedAt` timestamp (shouldn't happen in practice — `EventActions
    /// .complete` always stamps it — but handled defensively) falls back to its own
    /// `startDate` rather than being silently dropped from every bucket.
    private static func weeklyActivity(events: [KueEvent], now: Date, calendar: Calendar) -> [WeeklyActivityBucket] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var weekStarts: [Date] = []
        for offset in stride(from: weeklyActivityWeekCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart) else { continue }
            weekStarts.append(start)
        }
        guard let earliestBucketStart = weekStarts.first else { return [] }

        var eventCounts: [Date: Int] = [:]
        var taskCounts: [Date: Int] = [:]

        func bucketStart(for date: Date) -> Date? {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start, start >= earliestBucketStart else { return nil }
            return start
        }

        for event in events {
            let derivedStatus = EventStatusEngine.derive(for: event, now: now)
            if derivedStatus == .completed, let bucket = bucketStart(for: event.manuallyCompletedAt ?? event.startDate) {
                eventCounts[bucket, default: 0] += 1
            }
            guard !event.isCancelled else { continue }
            for task in event.tasks where task.isCompleted {
                if let completedAt = task.completedAt, let bucket = bucketStart(for: completedAt) {
                    taskCounts[bucket, default: 0] += 1
                }
            }
        }

        return weekStarts.map { start in
            WeeklyActivityBucket(weekStart: start, completedEventCount: eventCounts[start, default: 0], completedTaskCount: taskCounts[start, default: 0])
        }
    }
}
