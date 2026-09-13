//
//  SmartPlanningEngine.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36-smart-planning-and-productivity-intelligence.md. A pure,
//  deterministic planning engine: `(now, calendar, preferences, events, tasks, busy
//  intervals?, statistics?, suppressed-ids) -> TodayPlan`. No hidden `Date()` calls, no
//  SwiftData, no network — every date this engine reasons about is either `now` or a field
//  already on a snapshot. Calling `makePlan` twice with identical inputs always returns an
//  identical `TodayPlan` (`PlanningRecommendation.id` is content-derived, never `UUID()`), and
//  every value produced is `nonisolated`/`Sendable` so this can run off the main actor
//  (requirement M) — `PlanningSnapshotBuilder` is the only `@MainActor` step, and it's a cheap
//  field copy, not this engine's own scoring work.
//
//  **What "remaining preparation workload" means here**: `KueTask` has no duration/estimate
//  field (docs/03-data-model.md), so this engine never invents one — workload is expressed
//  honestly as *counts* (how many incomplete tasks, how many days remain), not fabricated
//  minutes. The only minute-denominated values anywhere in this file are focus-block lengths,
//  which come directly from `SmartPlanningPreferences.defaultFocusBlockMinutes` — a real user
//  preference, not invented data (requirement J: "avoid false precision").
//
//  **Task dependencies**: `KueTask` has no explicit dependency field either. The one
//  dependency relationship the data model actually supports is implicit ordering within one
//  event — a task is treated as "blocked" by any earlier-due, still-incomplete task on the
//  *same* event (`SchedulingEngine`'s own generated tasks are already due-date-ordered per
//  event). This engine only ever reasons about that one, data-supported relationship.
//
//  **Categories** (docs/36 "C."): all ten required categories are implemented below as
//  private `generate*` functions, each conservative by construction — most return `[]`
//  immediately unless their specific condition is actually met, exactly per requirement:
//  "Recommendations must be conservative. Do not generate meaningless advice merely to fill
//  the screen."
//

import Foundation

nonisolated struct SmartPlanningEngineInput: Sendable {
    let now: Date
    /// The device/user's own wall-clock calendar — used for "today," the planning window, and
    /// working-weekday checks. Each event's own day-bucketing still uses its pinned
    /// `timeZoneIdentifier`, exactly like `HomeTimelineGrouping` (see `dayStart(for:)` below).
    let calendar: Calendar
    let preferences: SmartPlanningPreferences
    let events: [PlanningEventSnapshot]
    let tasks: [PlanningTaskSnapshot]
    /// nil when Calendar access is unavailable/denied or the preference disables it — every
    /// consumer must treat nil as "unavailable," never as "confirmed empty" (requirement E/J).
    let busyIntervals: [DateInterval]?
    let statistics: ProfileStatistics?
    /// `PlanningRecommendation.id`s currently dismissed/snoozed — computed by the caller from
    /// `RecommendationDismissalStore` right before calling `makePlan`, so this engine itself
    /// never touches `UserDefaults` (keeps it a pure function of its arguments).
    let suppressedIDs: Set<String>

    init(
        now: Date, calendar: Calendar, preferences: SmartPlanningPreferences,
        events: [PlanningEventSnapshot], tasks: [PlanningTaskSnapshot],
        busyIntervals: [DateInterval]? = nil, statistics: ProfileStatistics? = nil,
        suppressedIDs: Set<String> = []
    ) {
        self.now = now
        self.calendar = calendar
        self.preferences = preferences
        self.events = events
        self.tasks = tasks
        self.busyIntervals = busyIntervals
        self.statistics = statistics
        self.suppressedIDs = suppressedIDs
    }
}

/// `nonisolated` (not the module's default `@MainActor`) so `makePlan` can run on a background
/// task — requirement M: "keep expensive computation off the main actor." Every parameter and
/// return type is itself `nonisolated`/`Sendable`, so this is safe to call from anywhere.
nonisolated enum SmartPlanningEngine {
    /// docs/36 "Today Plan": how far ahead a recommendation is allowed to live before it's
    /// considered stale and worth recomputing fresh — every recommendation's `expiresAt` is
    /// capped at this, even one about a much-later event, so nothing lingers un-refreshed for
    /// weeks (requirement B: "creation and expiry date").
    static let maximumRecommendationLifetime: TimeInterval = 24 * 60 * 60

    static func makePlan(_ input: SmartPlanningEngineInput) -> TodayPlan {
        guard input.preferences.masterEnabled else {
            return .empty(date: input.now, emptyStateMessage: "Smart Planning is turned off. Enable it in Settings to get a Today Plan.")
        }

        let todayStart = dayStart(for: input.now, timeZoneIdentifier: input.calendar.timeZone.identifier)
        guard let todayEnd = input.calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return .empty(date: input.now, emptyStateMessage: "Couldn't compute today's date.")
        }

        let activeEvents = input.events.filter { $0.status != .completed && $0.status != .cancelled }
        let context = Context(input: input, todayStart: todayStart, todayEnd: todayEnd, activeEvents: activeEvents)

        var recommendations: [PlanningRecommendation] = []
        recommendations += generateConfirmOutcome(context)
        recommendations += generateResolveConflicts(context)
        recommendations += generateReviewOverdueTask(context)
        recommendations += generateReduceTodaysLoad(context)
        recommendations += generateReviewAtRiskEvent(context)
        recommendations += generateMoveTaskEarlier(context)
        let (schedulePrep, scheduledSlotToday) = generateSchedulePreparation(context)
        recommendations += schedulePrep
        recommendations += generatePrepareForUpcomingEvent(context, coveredEventIDs: Set(schedulePrep.flatMap(\.affectedEventIDs)))
        recommendations += generateProtectFocusBlock(context, slotAlreadyUsedToday: scheduledSlotToday)
        recommendations += generateWorkOnNext(context)

        // Deterministic ordering: highest confidence first, then category declaration order
        // (a fixed, arbitrary-but-stable priority), then `id` — never insertion order alone,
        // so re-running with the same inputs (even after a dictionary-backed intermediate
        // step) always yields the same sequence (docs/36 "deterministic ordering").
        let categoryOrder: [RecommendationCategory: Int] = Dictionary(
            uniqueKeysWithValues: [
                RecommendationCategory.confirmEventOutcome, .resolveSchedulingConflict, .reviewOverdueTask,
                .reduceTodaysLoad, .reviewAtRiskEvent, .moveTaskEarlier, .schedulePreparation,
                .prepareForUpcomingEvent, .protectFocusBlock, .workOnNext,
            ].enumerated().map { ($1, $0) }
        )
        let visible = recommendations
            .filter { !input.suppressedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                let lhsOrder = categoryOrder[lhs.category] ?? .max
                let rhsOrder = categoryOrder[rhs.category] ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.id < rhs.id
            }

        let mostImportant = visible.first { $0.category == .workOnNext } ?? visible.first
        let urgent = visible.filter { [.reviewOverdueTask, .confirmEventOutcome].contains($0.category) }
        let conflicts = visible.filter { $0.category == .resolveSchedulingConflict }
        let risks = visible.filter { [.reviewAtRiskEvent, .prepareForUpcomingEvent, .schedulePreparation].contains($0.category) }
        let focusBlocks = visible.compactMap(\.focusBlock)

        let completedToday = context.tasksDueToday.filter(\.isCompleted).count
        let totalToday = context.tasksDueToday.count

        let limitedInfo: String? = (input.preferences.considerCalendarAvailability && input.busyIntervals == nil)
            ? "Calendar access isn't available, so conflicts are checked against Kue events only."
            : nil

        let emptyMessage: String? = visible.isEmpty
            ? "Nothing needs your attention right now. Kue will suggest something when it does."
            : nil

        return TodayPlan(
            date: input.now, mostImportantAction: mostImportant, orderedRecommendations: visible,
            focusBlocks: focusBlocks, urgentItems: urgent, conflicts: conflicts, preparationRisks: risks,
            completedTodayCount: completedToday, totalTodayCount: totalToday,
            limitedInformationNotice: limitedInfo, emptyStateMessage: emptyMessage
        )
    }

    // MARK: - Shared context

    /// Bundles everything every `generate*` function needs so their signatures stay short —
    /// purely a grouping convenience, computed once per `makePlan` call.
    private struct Context {
        let input: SmartPlanningEngineInput
        let todayStart: Date
        let todayEnd: Date
        /// Non-completed, non-cancelled events (archived is already excluded by the snapshot
        /// builder) — the working set almost every category reasons over.
        let activeEvents: [PlanningEventSnapshot]
        /// Built once per `makePlan` call — every `event(for:)`/`incompleteTasks(for:)` lookup
        /// below is O(1)/O(bucket) rather than an O(n) linear scan repeated per task, which
        /// matters at the 5,000-event scale `SmartPlanningPerformanceBenchmarkTests` measures.
        private let eventsByID: [UUID: PlanningEventSnapshot]
        private let incompleteTasksByEventID: [UUID: [PlanningTaskSnapshot]]
        /// Kue 3.0 Phase 8 correction pass — computed once here instead of as a computed
        /// property re-filtering `input.tasks` on every access (profiling showed these
        /// accessed several times per `makePlan` call; harmless at small scale, but "repeated
        /// scans of every task" per requirement M once counts climb).
        let incompleteTasks: [PlanningTaskSnapshot]
        let tasksDueToday: [PlanningTaskSnapshot]
        /// Kue 3.0 Phase 8 correction pass — the actual dominant cost found by direct
        /// profiling (`PROFILE schedulePreparation: 4.29s` of a 6.24s total 5,000-event run):
        /// `bestAvailableSlot` used to rebuild *and re-sort* this exact list from scratch on
        /// every call, and it's called once per candidate event in `generateSchedulePreparation`
        /// — at 5,000 events with most candidates qualifying, that's thousands of redundant
        /// O(n log n) sorts of a ~5,000-element array. Building it once, here, and having
        /// `bestAvailableSlot` read it turns that into one sort per `makePlan` call.
        let sortedBusyIntervals: [DateInterval]

        init(input: SmartPlanningEngineInput, todayStart: Date, todayEnd: Date, activeEvents: [PlanningEventSnapshot]) {
            self.input = input
            self.todayStart = todayStart
            self.todayEnd = todayEnd
            self.activeEvents = activeEvents
            self.eventsByID = Dictionary(uniqueKeysWithValues: input.events.map { ($0.id, $0) })
            var byEvent: [UUID: [PlanningTaskSnapshot]] = [:]
            for task in input.tasks where !task.isCompleted {
                guard let eventID = task.eventID else { continue }
                byEvent[eventID, default: []].append(task)
            }
            for key in byEvent.keys {
                byEvent[key]?.sort { $0.dueDate == $1.dueDate ? $0.sortOrder < $1.sortOrder : $0.dueDate < $1.dueDate }
            }
            self.incompleteTasksByEventID = byEvent
            self.incompleteTasks = input.tasks.filter { !$0.isCompleted }
            self.tasksDueToday = input.tasks.filter { $0.dueDate >= todayStart && $0.dueDate < todayEnd }

            var busy: [DateInterval] = activeEvents
                .filter { !$0.isAllDay && $0.status != .cancelled && $0.status != .completed }
                .map { DateInterval(start: $0.startDate, end: $0.effectiveEndDate) }
            if input.preferences.considerCalendarAvailability, let calendarBusy = input.busyIntervals {
                busy.append(contentsOf: calendarBusy)
            }
            busy.sort { $0.start < $1.start }
            self.sortedBusyIntervals = busy
        }

        var now: Date { input.now }
        var preferences: SmartPlanningPreferences { input.preferences }
        var intensity: PlanningIntensity { input.preferences.intensity }

        func event(for id: UUID?) -> PlanningEventSnapshot? {
            guard let id else { return nil }
            return eventsByID[id]
        }

        /// Every incomplete task on `event`, ordered by due date — the one data-supported
        /// ordering this engine treats as a dependency chain (see file header).
        func incompleteTasks(for event: PlanningEventSnapshot) -> [PlanningTaskSnapshot] {
            incompleteTasksByEventID[event.id] ?? []
        }

        /// Whole working days between `now` and `date`, counting only the preference's
        /// `workingWeekdays` — the honest denominator for "preparation work exceeding
        /// available days" (requirement J), never a raw calendar-day subtraction that counts
        /// weekends the user has already said they don't plan on.
        /// Kue 3.0 Phase 8 correction pass — was a day-by-day loop (`calendar.date(byAdding:)`
        /// + `component(.weekday:)` per day), O(days-until-`date`). Profiling at 5,000 events
        /// spread realistically across ~2 years showed this as the new dominant cost once the
        /// (unrealistic) conflict-explosion fixture was fixed — `generateReviewAtRiskEvent`/
        /// `generateMoveTaskEarlier` both call this once per future event with incomplete
        /// tasks, and a year-out event walked ~365 days to answer it. Any 7 consecutive
        /// calendar days contain each weekday exactly once, so full weeks contribute a fixed
        /// `workingWeekdays.count` each — only the remainder (< 7 days) needs the per-day walk.
        /// Same inputs → identical output to the old implementation for every date (see
        /// `SmartPlanningEngineTests`'s "workingDaysUntil optimization equivalence" section —
        /// exact full-week and remainder-day boundary cases).
        func workingDaysUntil(_ date: Date) -> Int {
            guard date > now else { return 0 }
            let calendar = input.calendar
            let start = calendar.startOfDay(for: now)
            let end = calendar.startOfDay(for: date)
            let totalDays = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            guard totalDays > 0 else { return 0 }

            let fullWeeks = totalDays / 7
            let remainderDays = totalDays % 7
            var count = fullWeeks * preferences.workingWeekdays.count

            var cursor = calendar.date(byAdding: .day, value: fullWeeks * 7, to: start) ?? start
            for _ in 0..<remainderDays {
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                let weekday = calendar.component(.weekday, from: next)
                if preferences.workingWeekdays.contains(weekday) { count += 1 }
                cursor = next
            }
            return count
        }
    }

    // MARK: - Confirm Event Outcome (never automatic completion — docs/36 "C.")

    private static func generateConfirmOutcome(_ ctx: Context) -> [PlanningRecommendation] {
        let awaiting = ctx.input.events
            .filter { $0.status == .awaitingOutcome }
            .sorted { $0.effectiveEndDate == $1.effectiveEndDate ? $0.id.uuidString < $1.id.uuidString : $0.effectiveEndDate > $1.effectiveEndDate }
        return awaiting.map { event in
            PlanningRecommendation(
                id: "confirmOutcome-\(event.id.uuidString)-\(dayFingerprint(event.effectiveEndDate))",
                category: .confirmEventOutcome,
                title: "How did \"\(event.title)\" go?",
                explanation: "This event ended and hasn't been marked complete, rescheduled, skipped, or cancelled yet.",
                contributingFactors: ["Ended \(relativeDayDescription(event.effectiveEndDate, now: ctx.now))"],
                confidence: .high,
                suggestedAction: .confirmOutcome,
                availableActions: [.confirmOutcome, .openEvent, .snooze],
                affectedEventIDs: [event.id],
                createdAt: ctx.now, expiresAt: ctx.now.addingTimeInterval(maximumRecommendationLifetime)
            )
        }
    }

    // MARK: - Resolve Scheduling Conflict

    private static func generateResolveConflicts(_ ctx: Context) -> [PlanningRecommendation] {
        let timed = ctx.activeEvents.filter { !$0.isAllDay && $0.status != .awaitingOutcome }
            .sorted { $0.startDate < $1.startDate }
        var results: [PlanningRecommendation] = []

        // `timed` is sorted by `startDate` ascending, so once a later event's start reaches
        // `timed[i]`'s own end, every event after it is even later still — safe to stop the
        // inner scan there instead of an unconditional O(n²) sweep (matters at the 5,000-
        // event scale `SmartPlanningPerformanceBenchmarkTests` measures).
        for i in 0..<timed.count {
            for j in (i + 1)..<timed.count {
                guard timed[j].startDate < timed[i].effectiveEndDate else { break }
                let a = timed[i], b = timed[j]
                let pairID = "conflict-\([a.id, b.id].map(\.uuidString).sorted().joined(separator: "-"))-\(dayFingerprint(a.startDate))"
                results.append(
                    PlanningRecommendation(
                        id: pairID, category: .resolveSchedulingConflict,
                        title: "\"\(a.title)\" overlaps \"\(b.title)\"",
                        explanation: "These two events are scheduled at overlapping times.",
                        contributingFactors: [
                            "\(a.title): \(a.startDate.formatted(date: .omitted, time: .shortened))–\(a.effectiveEndDate.formatted(date: .omitted, time: .shortened))",
                            "\(b.title): \(b.startDate.formatted(date: .omitted, time: .shortened))–\(b.effectiveEndDate.formatted(date: .omitted, time: .shortened))",
                        ],
                        confidence: .high, suggestedAction: .editBeforeApplying,
                        availableActions: [.openEvent, .dismiss, .snooze],
                        affectedEventIDs: [a.id, b.id],
                        createdAt: ctx.now, expiresAt: min(a.startDate, b.startDate)
                    )
                )
            }
        }

        // requirement J: focus blocks crossing another event — checked against already-
        // confirmed Kue events only (nothing is proposed yet at this point in `makePlan`, so
        // there's nothing to self-conflict with here); Calendar-busy overlap for a *proposed*
        // block is handled directly inside `bestAvailableSlot` before a block is ever offered.
        return results
    }

    // MARK: - Review Overdue Task

    private static func generateReviewOverdueTask(_ ctx: Context) -> [PlanningRecommendation] {
        let graceSeconds = ctx.intensity.overdueGraceHours * 3600
        let overdueCutoff = ctx.now.addingTimeInterval(-graceSeconds)

        // requirement C: an event already awaiting outcome confirmation gets exactly that
        // recommendation, not a second, redundant "your tasks are overdue" one about the same
        // already-past event.
        let awaitingIDs = Set(ctx.input.events.filter { $0.status == .awaitingOutcome }.map(\.id))

        var byEvent: [UUID: [PlanningTaskSnapshot]] = [:]
        for task in ctx.incompleteTasks where task.dueDate < overdueCutoff {
            guard let eventID = task.eventID, !awaitingIDs.contains(eventID) else { continue }
            guard let event = ctx.event(for: eventID), event.status != .cancelled, event.status != .completed else { continue }
            byEvent[eventID, default: []].append(task)
        }

        return byEvent.compactMap { eventID, tasks -> PlanningRecommendation? in
            guard let event = ctx.event(for: eventID) else { return nil }
            let sorted = tasks.sorted { $0.dueDate < $1.dueDate }
            let oldest = sorted[0]
            var factors = sorted.prefix(3).map { "\"\($0.title)\" was due \(relativeDayDescription($0.dueDate, now: ctx.now))" }
            if sorted.count > 3 { factors.append("+\(sorted.count - 3) more overdue task(s)") }
            return PlanningRecommendation(
                id: "overdueTask-\(eventID.uuidString)-\(dayFingerprint(ctx.todayStart))-\(sorted.count)",
                category: .reviewOverdueTask,
                title: sorted.count == 1 ? "\"\(oldest.title)\" is overdue" : "\(sorted.count) overdue tasks for \"\(event.title)\"",
                explanation: "These preparation tasks for \"\(event.title)\" are past their due date and not yet complete.",
                contributingFactors: factors, confidence: .high, suggestedAction: .openTask,
                availableActions: [.openTask, .openEvent, .dismiss, .snooze],
                affectedEventIDs: [eventID], affectedTaskIDs: sorted.map(\.id),
                createdAt: ctx.now, expiresAt: ctx.now.addingTimeInterval(maximumRecommendationLifetime)
            )
        }
    }

    // MARK: - Reduce Today's Load

    private static func generateReduceTodaysLoad(_ ctx: Context) -> [PlanningRecommendation] {
        let dueToday = ctx.tasksDueToday.filter { !$0.isCompleted }
        let timedToday = ctx.activeEvents.filter { !$0.isAllDay && $0.startDate >= ctx.todayStart && $0.startDate < ctx.todayEnd }
        let load = dueToday.count + timedToday.count
        let ceiling = Int((Double(ctx.preferences.maxDailyTaskLoad) * ctx.intensity.workloadMultiplier).rounded())
        guard load > ceiling, ceiling > 0 else { return [] }

        let highPriorityCount = timedToday.filter { $0.priority == .high }.count
        var factors = ["\(dueToday.count) task(s) due today", "\(timedToday.count) timed event(s) today"]
        if highPriorityCount > 1 {
            factors.append("\(highPriorityCount) high-priority events land on the same day")
        }
        // requirement: "optional productivity statistics" as an actual input, not merely
        // threaded through unused — corroborates (never invents) this recommendation with the
        // same privacy-limited numbers Insights already shows, only when the preference for
        // it is on.
        if let rate = ctx.input.statistics?.completionRate, rate < 0.5 {
            factors.append("Recent task completion rate: \(Int((rate * 100).rounded()))% — today's load may be harder to finish than it looks")
        }

        // Conservative candidate to move: the lowest-priority, farthest-from-its-own-event
        // task due today — never picked for a high-priority or already-overdue item.
        let candidate = dueToday
            .compactMap { task -> (PlanningTaskSnapshot, PlanningEventSnapshot)? in
                guard let event = ctx.event(for: task.eventID), event.priority != .high else { return nil }
                return (task, event)
            }
            .min { lhs, rhs in lhs.1.startDate > rhs.1.startDate } // event furthest away first

        // Next working day after today — a conservative one-day push, never further, and
        // never past the candidate's own event (Accept only ever offers a date that still
        // leaves real lead time before the event it belongs to).
        let nextWorkingDay: Date? = candidate.flatMap { _, event in
            var cursor = ctx.todayStart
            for _ in 0..<7 {
                guard let next = ctx.input.calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
                cursor = next
                let weekday = ctx.input.calendar.component(.weekday, from: cursor)
                if ctx.preferences.workingWeekdays.contains(weekday), cursor < event.startDate { return cursor }
            }
            return nil
        }

        return [
            PlanningRecommendation(
                id: "reduceLoad-\(dayFingerprint(ctx.todayStart))-\(load)",
                category: .reduceTodaysLoad,
                title: "Today looks overloaded",
                explanation: "\(load) items are scheduled today, above your \(ctx.intensity.displayName.lowercased()) comfortable load of \(ceiling).",
                contributingFactors: factors, confidence: .medium,
                suggestedAction: (candidate != nil && nextWorkingDay != nil) ? .editBeforeApplying : .dismiss,
                availableActions: (candidate != nil && nextWorkingDay != nil) ? [.editBeforeApplying, .dismiss, .snooze] : [.dismiss, .snooze],
                affectedEventIDs: candidate.map { [$0.1.id] } ?? [],
                affectedTaskIDs: candidate.map { [$0.0.id] } ?? [],
                createdAt: ctx.now, expiresAt: ctx.todayEnd, proposedDate: nextWorkingDay
            ),
        ]
    }

    // MARK: - Review an At-Risk Event (prep exceeds available days; all-day prep risk)

    private static func generateReviewAtRiskEvent(_ ctx: Context) -> [PlanningRecommendation] {
        var results: [PlanningRecommendation] = []
        for event in ctx.activeEvents where event.status != .awaitingOutcome && event.startDate > ctx.now {
            let remaining = ctx.incompleteTasks(for: event)
            guard !remaining.isEmpty else { continue }
            let availableDays = ctx.workingDaysUntil(event.startDate)
            guard remaining.count > max(availableDays, 0) else { continue }

            var factors = ["\(remaining.count) task(s) remaining", "\(availableDays) working day(s) left"]
            if event.isAllDay { factors.append("All-day event — preparation still needed") }

            results.append(
                PlanningRecommendation(
                    id: "atRisk-\(event.id.uuidString)-\(dayFingerprint(ctx.todayStart))-\(remaining.count)-\(availableDays)",
                    category: .reviewAtRiskEvent,
                    title: "\"\(event.title)\" may not be fully ready in time",
                    explanation: "There are more remaining preparation tasks than working days left before this event.",
                    contributingFactors: factors, confidence: availableDays <= 0 ? .high : .medium,
                    suggestedAction: .openEvent, availableActions: [.openEvent, .dismiss, .snooze],
                    affectedEventIDs: [event.id], affectedTaskIDs: remaining.map(\.id),
                    createdAt: ctx.now, expiresAt: event.startDate
                )
            )
        }
        return results
    }

    // MARK: - Move a Task Earlier

    private static func generateMoveTaskEarlier(_ ctx: Context) -> [PlanningRecommendation] {
        var results: [PlanningRecommendation] = []
        for event in ctx.activeEvents where event.startDate > ctx.now {
            let remaining = ctx.incompleteTasks(for: event)
            guard let last = remaining.last else { continue }
            // Only the task due closest to the event itself, and only when it's landed on
            // the same calendar day as the event start — the "last-minute crunch" case,
            // never a task that already has reasonable lead time.
            guard dayStart(for: last.dueDate, timeZoneIdentifier: event.timeZoneIdentifier) == dayStart(for: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier) else { continue }
            let availableDays = ctx.workingDaysUntil(event.startDate)
            guard availableDays >= 2 else { continue } // needs real slack to move into
            guard let earlierDate = ctx.input.calendar.date(byAdding: .day, value: -min(2, availableDays - 1), to: last.dueDate) else { continue }
            guard earlierDate > ctx.now else { continue }

            results.append(
                PlanningRecommendation(
                    id: "moveEarlier-\(last.id.uuidString)-\(dayFingerprint(last.dueDate))",
                    category: .moveTaskEarlier,
                    title: "Move \"\(last.title)\" earlier",
                    explanation: "This is currently due right before \"\(event.title)\" starts, with \(availableDays) working day(s) to spare — moving it earlier avoids a last-minute crunch.",
                    contributingFactors: ["Currently due \(last.dueDate.formatted(date: .abbreviated, time: .omitted))", "Event starts \(event.startDate.formatted(date: .abbreviated, time: .omitted))"],
                    confidence: .medium, suggestedAction: .accept,
                    availableActions: [.accept, .editBeforeApplying, .openTask, .dismiss, .snooze],
                    affectedEventIDs: [event.id], affectedTaskIDs: [last.id],
                    createdAt: ctx.now, expiresAt: last.dueDate, proposedDate: earlierDate
                )
            )
        }
        return results
    }

    // MARK: - Schedule Preparation (proposes a concrete focus block)

    /// Returns the recommendations plus whether a today-dated slot was consumed, so
    /// `generateProtectFocusBlock` doesn't double-propose the same open time.
    private static func generateSchedulePreparation(_ ctx: Context) -> ([PlanningRecommendation], Bool) {
        guard ctx.preferences.masterEnabled else { return ([], false) }
        var results: [PlanningRecommendation] = []
        var usedTodaySlot = false

        let candidates = ctx.activeEvents
            .filter { $0.startDate > ctx.now && $0.status != .awaitingOutcome }
            .filter { daysBetween(ctx.now, $0.startDate, calendar: ctx.input.calendar) <= ctx.intensity.riskLeadDays }
            .sorted { $0.startDate < $1.startDate }

        for event in candidates {
            let remaining = ctx.incompleteTasks(for: event)
            guard let nextTask = remaining.first else { continue }
            guard let slot = bestAvailableSlot(ctx, before: min(event.startDate, ctx.now.addingTimeInterval(48 * 3600))) else { continue }

            let block = FocusBlockProposal(
                id: "focus-\(nextTask.id.uuidString)-\(dayFingerprint(slot.start))",
                start: slot.start, durationMinutes: ctx.preferences.defaultFocusBlockMinutes,
                title: nextTask.title, taskID: nextTask.id, eventID: event.id
            )
            if dayStart(for: slot.start, timeZoneIdentifier: ctx.input.calendar.timeZone.identifier) == ctx.todayStart {
                usedTodaySlot = true
            }

            results.append(
                PlanningRecommendation(
                    id: "schedulePrep-\(nextTask.id.uuidString)-\(dayFingerprint(slot.start))",
                    category: .schedulePreparation,
                    title: "Schedule time for \"\(nextTask.title)\"",
                    explanation: "\"\(event.title)\" is coming up and this task isn't done yet — here's an open block that fits.",
                    contributingFactors: [
                        "\(daysBetween(ctx.now, event.startDate, calendar: ctx.input.calendar)) day(s) until \"\(event.title)\"",
                        "Proposed: \(slot.start.formatted(date: .abbreviated, time: .shortened)) for \(ctx.preferences.defaultFocusBlockMinutes) min",
                    ],
                    confidence: .medium, suggestedAction: .accept,
                    availableActions: [.accept, .editBeforeApplying, .addFocusBlockToCalendar, .dismiss, .snooze],
                    affectedEventIDs: [event.id], affectedTaskIDs: [nextTask.id],
                    createdAt: ctx.now, expiresAt: event.startDate, focusBlock: block
                )
            )
        }
        return (results, usedTodaySlot)
    }

    // MARK: - Prepare for Upcoming Event (fallback nudge when no concrete slot was found)

    private static func generatePrepareForUpcomingEvent(_ ctx: Context, coveredEventIDs: Set<UUID>) -> [PlanningRecommendation] {
        ctx.activeEvents
            .filter { $0.startDate > ctx.now && $0.status != .awaitingOutcome && !coveredEventIDs.contains($0.id) }
            .filter { daysBetween(ctx.now, $0.startDate, calendar: ctx.input.calendar) <= ctx.intensity.riskLeadDays }
            .compactMap { event -> PlanningRecommendation? in
                let remaining = ctx.incompleteTasks(for: event)
                guard !remaining.isEmpty else { return nil }
                let days = daysBetween(ctx.now, event.startDate, calendar: ctx.input.calendar)
                return PlanningRecommendation(
                    id: "prepareUpcoming-\(event.id.uuidString)-\(dayFingerprint(ctx.todayStart))-\(remaining.count)",
                    category: .prepareForUpcomingEvent,
                    title: "\"\(event.title)\" is in \(days) day(s)",
                    explanation: "\(remaining.count) preparation task(s) remain. No open block was found automatically — review and plan time yourself.",
                    contributingFactors: [
                        "\(remaining.count) task(s) remaining", "Starts \(event.startDate.formatted(date: .abbreviated, time: .omitted))",
                    ],
                    confidence: .low, suggestedAction: .openEvent,
                    availableActions: [.openEvent, .dismiss, .snooze],
                    affectedEventIDs: [event.id], affectedTaskIDs: remaining.map(\.id),
                    createdAt: ctx.now, expiresAt: event.startDate
                )
            }
    }

    // MARK: - Protect a Focus Block (safeguard open time for the top item generally)

    private static func generateProtectFocusBlock(_ ctx: Context, slotAlreadyUsedToday: Bool) -> [PlanningRecommendation] {
        guard !slotAlreadyUsedToday else { return [] }
        guard let topTask = ctx.tasksDueToday.filter({ !$0.isCompleted }).min(by: { $0.dueDate < $1.dueDate })
                ?? ctx.incompleteTasks.min(by: { $0.dueDate < $1.dueDate }) else { return [] }
        guard let slot = bestAvailableSlot(ctx, before: ctx.todayEnd) else { return [] }
        guard dayStart(for: slot.start, timeZoneIdentifier: ctx.input.calendar.timeZone.identifier) == ctx.todayStart else { return [] }

        let block = FocusBlockProposal(
            id: "protect-\(topTask.id.uuidString)-\(dayFingerprint(slot.start))",
            start: slot.start, durationMinutes: ctx.preferences.defaultFocusBlockMinutes,
            title: topTask.title, taskID: topTask.id, eventID: topTask.eventID
        )
        return [
            PlanningRecommendation(
                id: "protectFocus-\(topTask.id.uuidString)-\(dayFingerprint(slot.start))",
                category: .protectFocusBlock,
                title: "Protect time for \"\(topTask.title)\"",
                explanation: "You have an open block today that fits this task — reserve it before something else fills it.",
                contributingFactors: ["Open from \(slot.start.formatted(date: .omitted, time: .shortened)) to \(slot.end.formatted(date: .omitted, time: .shortened))"],
                confidence: .medium, suggestedAction: .accept,
                availableActions: [.accept, .editBeforeApplying, .addFocusBlockToCalendar, .startFocus, .dismiss, .snooze],
                affectedEventIDs: topTask.eventID.map { [$0] } ?? [], affectedTaskIDs: [topTask.id],
                createdAt: ctx.now, expiresAt: ctx.todayEnd, focusBlock: block
            ),
        ]
    }

    // MARK: - Work on Next (the single most important next action)

    private static func generateWorkOnNext(_ ctx: Context) -> [PlanningRecommendation] {
        // Conservative scope: only ever picks from tasks already due (today or overdue) on a
        // non-terminal event — never a task due in the distant future, which "Prepare for
        // Upcoming Event"/"Schedule Preparation" already cover.
        let candidates = ctx.incompleteTasks
            .filter { $0.dueDate <= ctx.todayEnd }
            .compactMap { task -> (PlanningTaskSnapshot, PlanningEventSnapshot)? in
                guard let event = ctx.event(for: task.eventID), event.status != .completed, event.status != .cancelled else { return nil }
                return (task, event)
            }
        guard let top = candidates.min(by: { lhs, rhs in
            urgencyScore(lhs.0, lhs.1, now: ctx.now) > urgencyScore(rhs.0, rhs.1, now: ctx.now)
        }) else { return [] }

        let (task, event) = top
        let overdue = task.dueDate < ctx.now
        return [
            PlanningRecommendation(
                id: "workOnNext-\(task.id.uuidString)-\(dayFingerprint(ctx.todayStart))",
                category: .workOnNext,
                title: task.title,
                explanation: overdue
                    ? "This is the most overdue task on your highest-priority active event."
                    : "This is your highest-priority task due today.",
                contributingFactors: [
                    "Due \(relativeDayDescription(task.dueDate, now: ctx.now))",
                    "Part of \"\(event.title)\" (\(event.priority.rawValue) priority)",
                ],
                confidence: .high, suggestedAction: .openTask,
                availableActions: [.openTask, .openEvent, .startFocus, .dismiss, .snooze],
                affectedEventIDs: [event.id], affectedTaskIDs: [task.id],
                createdAt: ctx.now, expiresAt: ctx.todayEnd
            ),
        ]
    }

    // MARK: - Scoring

    private static func urgencyScore(_ task: PlanningTaskSnapshot, _ event: PlanningEventSnapshot, now: Date) -> Double {
        let hoursOverdue = max(0, now.timeIntervalSince(task.dueDate)) / 3600
        let importance: Double
        switch event.priority {
        case .high: importance = 3
        case .medium: importance = 2
        case .low: importance = 1
        }
        return hoursOverdue * 2 + importance * 10
    }

    // MARK: - Focus-block placement (requirement E: avoid overlaps with Kue events + Calendar)

    private struct Slot { let start: Date; let end: Date }

    /// The earliest open slot of at least `defaultFocusBlockMinutes`, at or after `now`,
    /// inside today's planning window, that overlaps neither an active Kue event nor (when
    /// available) an imported Calendar busy interval — `nil` when nothing fits before
    /// `deadline` or outside working days/hours.
    private static func bestAvailableSlot(_ ctx: Context, before deadline: Date) -> Slot? {
        let duration = TimeInterval(ctx.preferences.defaultFocusBlockMinutes * 60)
        guard duration > 0 else { return nil }

        let calendar = ctx.input.calendar
        var dayCursor = calendar.startOfDay(for: ctx.now)
        let searchLimit = min(deadline, ctx.now.addingTimeInterval(7 * 24 * 3600)) // never search further than a week out

        // Precomputed once per `makePlan` call on `Context` — see that struct's own comment
        // for why this used to be rebuilt (and re-sorted) on every single call here.
        let busy = ctx.sortedBusyIntervals

        while dayCursor < searchLimit {
            let weekday = calendar.component(.weekday, from: dayCursor)
            if ctx.preferences.workingWeekdays.contains(weekday),
               let windowStart = calendar.date(byAdding: .minute, value: ctx.preferences.planningWindowStartMinute, to: dayCursor),
               let windowEnd = calendar.date(byAdding: .minute, value: ctx.preferences.planningWindowEndMinute, to: dayCursor) {
                var cursor = max(windowStart, ctx.now)
                let effectiveEnd = min(windowEnd, searchLimit)
                let dayBusy = busy.filter { $0.end > cursor && $0.start < effectiveEnd }
                for interval in dayBusy {
                    if interval.start.timeIntervalSince(cursor) >= duration {
                        return Slot(start: cursor, end: cursor.addingTimeInterval(duration))
                    }
                    cursor = max(cursor, interval.end)
                }
                if effectiveEnd.timeIntervalSince(cursor) >= duration {
                    return Slot(start: cursor, end: cursor.addingTimeInterval(duration))
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayCursor) else { break }
            dayCursor = nextDay
        }
        return nil
    }

    // MARK: - Date helpers (docs/36: all math via `Calendar`, never raw `TimeInterval`, for DST safety)

    private static func dayStart(for date: Date, timeZoneIdentifier: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar.startOfDay(for: date)
    }

    private static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
    }

    /// A coarse, stable fingerprint (day granularity) baked into recommendation ids so a
    /// meaningfully different date produces a different id — see this file's own header and
    /// `RecommendationDismissalStore`'s "deterministic expiry" note.
    private static func dayFingerprint(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 86_400)
    }

    private static func relativeDayDescription(_ date: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}
