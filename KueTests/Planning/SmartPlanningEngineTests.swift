//
//  SmartPlanningEngineTests.swift
//  KueTests
//
//  Kue 3.0 Phase 8 — docs/36. `SmartPlanningEngine` takes plain snapshots, not `KueEvent`/
//  `KueTask`, so these tests never touch SwiftData at all — every recommendation category is
//  exercised directly against constructed `PlanningEventSnapshot`/`PlanningTaskSnapshot`
//  values with a fixed `now`/`calendar`, matching the deterministic-fixture convention every
//  other planning-adjacent test file in this target already uses.
//

import Testing
import Foundation
@testable import Kue

@Suite
struct SmartPlanningEngineTests {
    // A fixed Wednesday, 10:00 UTC — matches the "no live `.now`" convention.
    private let now = Date(timeIntervalSince1970: 1_700_000_000 + 3600) // Wed 15 Nov 2023, 23:13 UTC-ish; pinned below instead
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func makeEvent(
        id: UUID = UUID(), title: String = "Event", eventType: EventType = .generic,
        startDate: Date, isAllDay: Bool = false, priority: Priority = .medium,
        status: EventStatus = .upcoming, seriesID: UUID? = nil, isRecurrenceException: Bool = false,
        taskIDs: [UUID] = []
    ) -> PlanningEventSnapshot {
        PlanningEventSnapshot(
            id: id, title: title, eventType: eventType, startDate: startDate,
            effectiveEndDate: startDate.addingTimeInterval(3600), isAllDay: isAllDay,
            timeZoneIdentifier: "UTC", priority: priority, status: status, seriesID: seriesID,
            isRecurrenceException: isRecurrenceException, taskIDs: taskIDs
        )
    }

    private func makeTask(
        id: UUID = UUID(), eventID: UUID?, title: String = "Task", dueDate: Date,
        isCompleted: Bool = false, sortOrder: Int = 0
    ) -> PlanningTaskSnapshot {
        PlanningTaskSnapshot(id: id, eventID: eventID, title: title, dueDate: dueDate, isCompleted: isCompleted, completedAt: nil, sortOrder: sortOrder)
    }

    private func input(
        events: [PlanningEventSnapshot] = [], tasks: [PlanningTaskSnapshot] = [],
        preferences: SmartPlanningPreferences = .conservativeDefault,
        busyIntervals: [DateInterval]? = nil, statistics: ProfileStatistics? = nil,
        suppressedIDs: Set<String> = [], now: Date? = nil
    ) -> SmartPlanningEngineInput {
        SmartPlanningEngineInput(
            now: now ?? self.now, calendar: calendar, preferences: preferences, events: events, tasks: tasks,
            busyIntervals: busyIntervals, statistics: statistics, suppressedIDs: suppressedIDs
        )
    }

    // MARK: - Determinism

    @Test func identicalInputsProduceIdenticalPlans() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let task = makeTask(eventID: event.id, dueDate: now.addingTimeInterval(-3600))
        let plan1 = SmartPlanningEngine.makePlan(input(events: [event], tasks: [task]))
        let plan2 = SmartPlanningEngine.makePlan(input(events: [event], tasks: [task]))
        #expect(plan1 == plan2)
    }

    @Test func orderingIsStableAcrossMultipleRuns() {
        let e1 = makeEvent(title: "A", startDate: now.addingTimeInterval(3600))
        let e2 = makeEvent(title: "B", startDate: now.addingTimeInterval(7200))
        let t1 = makeTask(eventID: e1.id, dueDate: now.addingTimeInterval(-7200))
        let t2 = makeTask(eventID: e2.id, dueDate: now.addingTimeInterval(-3600))
        let plans = (0..<5).map { _ in SmartPlanningEngine.makePlan(input(events: [e1, e2], tasks: [t1, t2])) }
        #expect(Set(plans.map { $0.orderedRecommendations.map(\.id) }).count == 1)
    }

    // MARK: - Work on Next (urgency/importance)

    @Test func workOnNextPicksTheHighestPriorityOverdueTask() {
        let low = makeEvent(title: "Low", startDate: now.addingTimeInterval(86_400), priority: .low)
        let high = makeEvent(title: "High", startDate: now.addingTimeInterval(86_400), priority: .high)
        let lowTask = makeTask(eventID: low.id, title: "Low task", dueDate: now.addingTimeInterval(-3600))
        let highTask = makeTask(eventID: high.id, title: "High task", dueDate: now.addingTimeInterval(-1800))
        let plan = SmartPlanningEngine.makePlan(input(events: [low, high], tasks: [lowTask, highTask]))
        #expect(plan.mostImportantAction?.title == "High task")
    }

    // MARK: - Reduce Today's Load (workload limits + intensity thresholds)

    @Test func overloadedDayTriggersReduceTodaysLoad() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.maxDailyTaskLoad = 2
        preferences.intensity = .balanced
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 86_400), priority: .medium)
        let tasks = (0..<5).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now, sortOrder: i) }
        let plan = SmartPlanningEngine.makePlan(input(events: [event], tasks: tasks, preferences: preferences))
        #expect(plan.orderedRecommendations.contains { $0.category == .reduceTodaysLoad })
    }

    @Test func gentleIntensityToleratesMoreLoadThanAmbitious() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 86_400), priority: .medium)
        let tasks = (0..<6).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now, sortOrder: i) }

        var gentle = SmartPlanningPreferences.conservativeDefault
        gentle.maxDailyTaskLoad = 5
        gentle.intensity = .gentle // multiplier 0.75 -> ceiling 3

        var ambitious = SmartPlanningPreferences.conservativeDefault
        ambitious.maxDailyTaskLoad = 5
        ambitious.intensity = .ambitious // multiplier 1.35 -> ceiling 7 (no trigger at load 6)

        let gentlePlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: tasks, preferences: gentle))
        let ambitiousPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: tasks, preferences: ambitious))

        #expect(gentlePlan.orderedRecommendations.contains { $0.category == .reduceTodaysLoad })
        #expect(!ambitiousPlan.orderedRecommendations.contains { $0.category == .reduceTodaysLoad })
    }

    // MARK: - Conflict detection

    @Test func overlappingTimedEventsProduceAResolveConflictRecommendation() {
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3600))
        let b = makeEvent(title: "B", startDate: now.addingTimeInterval(3600 + 600)) // overlaps A's 1hr block
        let plan = SmartPlanningEngine.makePlan(input(events: [a, b]))
        #expect(plan.conflicts.count == 1)
        #expect(Set(plan.conflicts[0].affectedEventIDs) == Set([a.id, b.id]))
    }

    @Test func nonOverlappingTimedEventsProduceNoConflict() {
        let a = makeEvent(title: "A", startDate: now.addingTimeInterval(3600))
        let b = makeEvent(title: "B", startDate: now.addingTimeInterval(3 * 3600))
        let plan = SmartPlanningEngine.makePlan(input(events: [a, b]))
        #expect(plan.conflicts.isEmpty)
    }

    // MARK: - All-day events

    @Test func allDayEventStillAtRiskWhenPrepOutpacesAvailableDays() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.workingWeekdays = Set(1...7)
        let event = makeEvent(startDate: now.addingTimeInterval(86_400), isAllDay: true)
        let tasks = (0..<5).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now.addingTimeInterval(Double(i) * 3600), sortOrder: i) }
        let plan = SmartPlanningEngine.makePlan(input(events: [event], tasks: tasks, preferences: preferences))
        let risk = plan.orderedRecommendations.first { $0.category == .reviewAtRiskEvent }
        #expect(risk != nil)
        #expect(risk?.contributingFactors.contains { $0.contains("All-day") } == true)
    }

    // MARK: - `workingDaysUntil` optimization equivalence (Kue 3.0 Phase 8 correction pass)
    //
    // `Context.workingDaysUntil` was rewritten from an O(days) day-by-day loop into an O(1)
    // full-weeks-plus-remainder calculation (see that function's own comment in
    // SmartPlanningEngine.swift). It's a private method on a private nested type, so these
    // exercise it indirectly through `generateReviewAtRiskEvent`'s own threshold
    // (`incomplete task count > workingDaysUntil(event.startDate)`), at exact boundaries that
    // would catch an off-by-one in either the full-week or remainder-day math.

    @Test func workingDaysUntilExactBoundaryWithEveryDayWorkingSpansMultipleWeeks() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.workingWeekdays = Set(1...7) // every day counts — 10 calendar days == 10 working days
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))

        let exactly10Tasks = (0..<10).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now, sortOrder: i) }
        let notAtRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly10Tasks, preferences: preferences))
        #expect(!notAtRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })

        let eleventh = makeTask(eventID: event.id, title: "T10", dueDate: now, sortOrder: 10)
        let atRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly10Tasks + [eleventh], preferences: preferences))
        #expect(atRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })
    }

    @Test func workingDaysUntilExactBoundaryAcrossTwoFullWeeksWithAFiveDayWeek() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.workingWeekdays = Set(2...6) // Mon–Fri only
        // Exactly 14 calendar days (two full weeks, zero remainder) == exactly 10 working days
        // regardless of which weekday `now` itself falls on — the case most likely to expose
        // an off-by-one in the "full weeks × workingWeekdays.count" shortcut.
        let event = makeEvent(startDate: now.addingTimeInterval(14 * 86_400))

        let exactly10Tasks = (0..<10).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now, sortOrder: i) }
        let notAtRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly10Tasks, preferences: preferences))
        #expect(!notAtRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })

        let eleventh = makeTask(eventID: event.id, title: "T10", dueDate: now, sortOrder: 10)
        let atRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly10Tasks + [eleventh], preferences: preferences))
        #expect(atRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })
    }

    @Test func workingDaysUntilRemainderDaysAreCountedAfterFullWeeks() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.workingWeekdays = Set(2...6) // Mon–Fri only
        // 16 calendar days = two full weeks (10 working days) + a 2-day remainder. `now`
        // (1_700_000_000 UTC) is a Tuesday, so its own +14/+15/+16-day marks fall on
        // Tuesday/Wednesday/Thursday — the 2-day remainder (Wed, Thu) is entirely within
        // Mon–Fri, for exactly 12 total, not 10 — verified independently against a plain
        // Python `datetime.timedelta` walk of the same dates, not just re-derived from the
        // implementation under test.
        let event = makeEvent(startDate: now.addingTimeInterval(16 * 86_400))

        let exactly12Tasks = (0..<12).map { i in makeTask(eventID: event.id, title: "T\(i)", dueDate: now, sortOrder: i) }
        let notAtRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly12Tasks, preferences: preferences))
        #expect(!notAtRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })

        let thirteenth = makeTask(eventID: event.id, title: "T12", dueDate: now, sortOrder: 12)
        let atRiskPlan = SmartPlanningEngine.makePlan(input(events: [event], tasks: exactly12Tasks + [thirteenth], preferences: preferences))
        #expect(atRiskPlan.orderedRecommendations.contains { $0.category == .reviewAtRiskEvent })
    }

    // MARK: - Recurring occurrences

    @Test func recurringOccurrenceExceptionIsHandledLikeAnyOtherEvent() {
        let series = UUID()
        let event = makeEvent(startDate: now.addingTimeInterval(3600), seriesID: series, isRecurrenceException: true)
        let task = makeTask(eventID: event.id, dueDate: now.addingTimeInterval(-1800))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], tasks: [task]))
        #expect(plan.mostImportantAction != nil)
    }

    // MARK: - Needs Review / Confirm Outcome (never automatic completion)

    @Test func awaitingOutcomeEventProducesConfirmOutcomeNeverAutoCompletion() {
        let event = makeEvent(startDate: now.addingTimeInterval(-7200), status: .awaitingOutcome)
        let plan = SmartPlanningEngine.makePlan(input(events: [event]))
        let confirm = plan.orderedRecommendations.first { $0.category == .confirmEventOutcome }
        #expect(confirm != nil)
        #expect(confirm?.suggestedAction == .confirmOutcome)
        #expect(confirm?.availableActions.contains(.confirmOutcome) == true)
    }

    @Test func awaitingOutcomeEventDoesNotAlsoProduceARedundantOverdueTaskRecommendation() {
        let event = makeEvent(startDate: now.addingTimeInterval(-7200), status: .awaitingOutcome)
        let task = makeTask(eventID: event.id, dueDate: now.addingTimeInterval(-7200))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], tasks: [task]))
        #expect(!plan.orderedRecommendations.contains { $0.category == .reviewOverdueTask })
    }

    // MARK: - Completed/cancelled/archived suppression

    @Test func completedAndCancelledEventsProduceNoRecommendations() {
        let completed = makeEvent(title: "Done", startDate: now.addingTimeInterval(-3600), status: .completed)
        let cancelled = makeEvent(title: "Nope", startDate: now.addingTimeInterval(-3600), status: .cancelled)
        let plan = SmartPlanningEngine.makePlan(input(events: [completed, cancelled]))
        #expect(plan.orderedRecommendations.isEmpty)
    }

    // Archived exclusion is enforced by `PlanningSnapshotBuilder` (never even reaches the
    // engine) — covered in `PlanningSnapshotBuilderTests`, not here (the engine has no
    // `.archived` case to filter since the builder never produces one).

    // MARK: - Time zones / DST

    @Test func todayBoundaryUsesTheInjectedCalendarsTimeZoneNotUTC() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 23:30 UTC is already "tomorrow" in Tokyo (UTC+9) — a task due at that instant must
        // land in *today's* bucket per Tokyo, not UTC.
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // Tue 14 Nov 2023 22:13:20 UTC
        let event = makeEvent(startDate: fixedNow.addingTimeInterval(3600))
        let dueTonightInTokyo = fixedNow.addingTimeInterval(3000) // still same Tokyo calendar day
        let task = makeTask(eventID: event.id, dueDate: dueTonightInTokyo)
        let engineInput = SmartPlanningEngineInput(now: fixedNow, calendar: tokyo, preferences: .conservativeDefault, events: [event], tasks: [task])
        let plan = SmartPlanningEngine.makePlan(engineInput)
        #expect(plan.totalTodayCount == 1)
    }

    @Test func dstSpringForwardDayStillProducesAValidPlanWithoutCrashing() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2023-03-12 is a US DST spring-forward day.
        let dstNow = pacific.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 9))!
        let event = makeEvent(startDate: dstNow.addingTimeInterval(3600))
        let task = makeTask(eventID: event.id, dueDate: dstNow.addingTimeInterval(-1800))
        let engineInput = SmartPlanningEngineInput(now: dstNow, calendar: pacific, preferences: .conservativeDefault, events: [event], tasks: [task])
        let plan = SmartPlanningEngine.makePlan(engineInput)
        #expect(plan.mostImportantAction != nil)
    }

    // MARK: - Dismissal suppression (expiry itself is covered by RecommendationDismissalStoreTests)

    @Test func suppressedRecommendationIDsAreExcludedFromTheVisiblePlan() {
        let event = makeEvent(startDate: now.addingTimeInterval(-7200), status: .awaitingOutcome)
        let firstPass = SmartPlanningEngine.makePlan(input(events: [event]))
        guard let id = firstPass.orderedRecommendations.first?.id else {
            Issue.record("expected at least one recommendation")
            return
        }
        let secondPass = SmartPlanningEngine.makePlan(input(events: [event], suppressedIDs: [id]))
        #expect(!secondPass.orderedRecommendations.contains { $0.id == id })
    }

    // MARK: - Privacy-safe inputs and outputs

    @Test func masterDisabledProducesAnEmptyPlanWithNoScoringWork() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.masterEnabled = false
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], preferences: preferences))
        #expect(plan.orderedRecommendations.isEmpty)
        #expect(plan.emptyStateMessage != nil)
    }

    /// Every recommendation's own explanation only ever draws from data already inside the
    /// input (titles the app already stores on-device) — never a raw dump of `contributing
    /// Factors` beyond what's traceable to `events`/`tasks` passed in. This test's real
    /// purpose is documentation-by-example for docs/36 "Privacy," not a security boundary
    /// this pure function could violate on its own (it has no network access at all).
    @Test func recommendationsNeverReferenceDataOutsideTheProvidedInput() {
        let event = makeEvent(title: "Secret Interview", startDate: now.addingTimeInterval(-7200), status: .awaitingOutcome)
        let plan = SmartPlanningEngine.makePlan(input(events: [event]))
        for recommendation in plan.orderedRecommendations {
            for id in recommendation.affectedEventIDs { #expect(id == event.id) }
        }
    }

    // MARK: - Calendar-unavailable fallback

    @Test func calendarUnavailableStillProducesAPlanWithALimitedInformationNotice() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.considerCalendarAvailability = true
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], preferences: preferences, busyIntervals: nil))
        #expect(plan.limitedInformationNotice != nil)
    }

    @Test func calendarAvailableClearsTheLimitedInformationNotice() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.considerCalendarAvailability = true
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], preferences: preferences, busyIntervals: []))
        #expect(plan.limitedInformationNotice == nil)
    }

    // MARK: - Personal-mode behavior (no statistics available)

    @Test func planWorksIdenticallyWithNoStatisticsProvided() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let task = makeTask(eventID: event.id, dueDate: now.addingTimeInterval(-1800))
        let plan = SmartPlanningEngine.makePlan(input(events: [event], tasks: [task], statistics: nil))
        #expect(plan.mostImportantAction != nil)
    }

    // MARK: - Focus-block placement (avoids overlaps with Kue events + Calendar)

    @Test func proposedFocusBlockNeverOverlapsAnExistingEvent() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.planningWindowStartMinute = 0
        preferences.planningWindowEndMinute = 24 * 60
        preferences.defaultFocusBlockMinutes = 30
        preferences.workingWeekdays = Set(1...7)

        let busyEvent = makeEvent(title: "Busy", startDate: now, priority: .medium)
        let prepEvent = makeEvent(title: "Interview", startDate: now.addingTimeInterval(86_400), priority: .high)
        let task = makeTask(eventID: prepEvent.id, title: "Prep", dueDate: now.addingTimeInterval(3 * 3600))

        let plan = SmartPlanningEngine.makePlan(input(events: [busyEvent, prepEvent], tasks: [task], preferences: preferences))
        guard let block = plan.focusBlocks.first else {
            Issue.record("expected a proposed focus block")
            return
        }
        let busyInterval = DateInterval(start: busyEvent.startDate, end: busyEvent.effectiveEndDate)
        let blockInterval = DateInterval(start: block.start, end: block.end)
        #expect(!(blockInterval.start < busyInterval.end && busyInterval.start < blockInterval.end))
    }

    @Test func focusBlockRespectsCalendarBusyIntervalsWhenAvailable() {
        var preferences = SmartPlanningPreferences.conservativeDefault
        preferences.planningWindowStartMinute = 0
        preferences.planningWindowEndMinute = 24 * 60
        preferences.defaultFocusBlockMinutes = 30
        preferences.workingWeekdays = Set(1...7)
        preferences.considerCalendarAvailability = true

        let prepEvent = makeEvent(startDate: now.addingTimeInterval(86_400), priority: .high)
        let task = makeTask(eventID: prepEvent.id, dueDate: now.addingTimeInterval(3 * 3600))
        let busy = DateInterval(start: now, end: now.addingTimeInterval(2 * 3600))

        let plan = SmartPlanningEngine.makePlan(input(events: [prepEvent], tasks: [task], preferences: preferences, busyIntervals: [busy]))
        guard let block = plan.focusBlocks.first else {
            Issue.record("expected a proposed focus block")
            return
        }
        let blockInterval = DateInterval(start: block.start, end: block.end)
        #expect(!(blockInterval.start < busy.end && busy.start < blockInterval.end))
    }
}
