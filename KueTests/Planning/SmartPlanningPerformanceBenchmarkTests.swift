//
//  SmartPlanningPerformanceBenchmarkTests.swift
//  KueTests
//
//  Kue 3.0 Phase 8 — docs/36 "M. Performance." Same shape as
//  `KueMacTests/SyncPerformanceBenchmarkTests.swift`'s own header: print the real measured
//  number, assert only a generous timing floor (never a tight one a slower CI machine could
//  flake on), and assert correctness independent of timing. Pure `SmartPlanningEngineInput`
//  values — no SwiftData at all — so this measures the engine's own scoring cost exactly as
//  `TodayPlanViewModel` would experience it off the main actor, at 100/1,000/5,000 events with
//  tasks and recurring occurrences mixed in. Simulator-only numbers — see docs/36's own
//  physical-device disclosure; this is not a device-scale guarantee.
//

import Testing
import Foundation
@testable import Kue

@Suite
struct SmartPlanningPerformanceBenchmarkTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture(eventCount: Int) -> (events: [PlanningEventSnapshot], tasks: [PlanningTaskSnapshot]) {
        var events: [PlanningEventSnapshot] = []
        var tasks: [PlanningTaskSnapshot] = []
        events.reserveCapacity(eventCount)

        // Every 10th event is one occurrence of a 5-occurrence recurring series — a realistic
        // mix of standalone and recurring events, not an artificially uniform dataset.
        var seriesCounter = 0
        for i in 0..<eventCount {
            let isRecurring = i % 10 == 0
            let seriesID: UUID? = isRecurring ? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seriesCounter / 5)) : nil
            if isRecurring { seriesCounter += 1 }

            let eventID = UUID()
            // Kue 3.0 Phase 8 correction pass: the original formula (`i % 60` hours) clustered
            // every event into a ~60-hour window regardless of `eventCount` — at 5,000 events
            // that's ~83 events per hour, all overlapping, which made `generateResolveConflicts`
            // construct (and `finalSort` then sort) on the order of 200,000 pairwise-conflict
            // recommendations — a real cost, but an artifact of an unrealistic fixture, not a
            // representative "5,000 real events" measurement. Spread across a ~2-year window
            // instead (roughly one event every few hours at 5,000 events, sparser at 100/1,000)
            // — realistic enough that genuine overlaps are the exception, not the rule, matching
            // an actual multi-year power-user calendar.
            let totalSpanHours = 24.0 * 365 * 2
            let hourOffset = (Double(i) - Double(eventCount) / 2) * (totalSpanHours / Double(eventCount))
            let start = now.addingTimeInterval(hourOffset * 3600)
            let priority: Priority = [.low, .medium, .high][i % 3]
            // Mostly upcoming/today/tomorrow; every 20th is awaiting outcome (a real past
            // event needing a decision) — a realistic minority, not half the dataset.
            let status: EventStatus = i % 20 == 19 ? .awaitingOutcome : [.upcoming, .today, .tomorrow][i % 3]

            var taskIDs: [UUID] = []
            if i % 4 != 0 { // most events have 1-3 prep tasks
                for t in 0..<((i % 3) + 1) {
                    let taskID = UUID()
                    taskIDs.append(taskID)
                    tasks.append(PlanningTaskSnapshot(
                        id: taskID, eventID: eventID, title: "Task \(i)-\(t)",
                        dueDate: start.addingTimeInterval(TimeInterval(-t - 1) * 3600),
                        isCompleted: (i + t) % 5 == 0, completedAt: nil, sortOrder: t
                    ))
                }
            }

            events.append(PlanningEventSnapshot(
                id: eventID, title: "Benchmark Event \(i)", eventType: EventType.allCases[i % EventType.allCases.count],
                startDate: start, effectiveEndDate: start.addingTimeInterval(3600), isAllDay: i % 15 == 0,
                timeZoneIdentifier: "UTC", priority: priority, status: status, seriesID: seriesID,
                isRecurrenceException: isRecurring && i % 50 == 0, taskIDs: taskIDs
            ))
        }
        return (events, tasks)
    }

    private func runBenchmark(eventCount: Int) -> Duration {
        let (events, tasks) = makeFixture(eventCount: eventCount)
        let input = SmartPlanningEngineInput(
            now: now, calendar: Calendar(identifier: .gregorian), preferences: .conservativeDefault,
            events: events, tasks: tasks, busyIntervals: nil, statistics: nil
        )
        let clock = ContinuousClock()
        let start = clock.now
        let plan = SmartPlanningEngine.makePlan(input)
        let elapsed = clock.now - start
        // Correctness independent of timing: a plan was actually produced, deterministically.
        #expect(plan.date == now)
        return elapsed
    }

    @Test func oneHundredEventBenchmark() {
        let elapsed = runBenchmark(eventCount: 100)
        print("SmartPlanningEngine — 100 events: \(elapsed)")
        #expect(elapsed < .seconds(2)) // generous floor — see file header
    }

    @Test func oneThousandEventBenchmark() {
        let elapsed = runBenchmark(eventCount: 1_000)
        print("SmartPlanningEngine — 1,000 events: \(elapsed)")
        #expect(elapsed < .seconds(5))
    }

    @Test func fiveThousandEventBenchmark() {
        let elapsed = runBenchmark(eventCount: 5_000)
        print("SmartPlanningEngine — 5,000 events: \(elapsed)")
        #expect(elapsed < .seconds(15))
    }

    /// Same 5,000-event fixture, run twice — confirms output is identical (determinism holds
    /// even at scale, not just in the small hand-built fixtures in `SmartPlanningEngineTests`).
    @Test func fiveThousandEventPlanIsDeterministic() {
        let (events, tasks) = makeFixture(eventCount: 5_000)
        let input = SmartPlanningEngineInput(now: now, calendar: Calendar(identifier: .gregorian), preferences: .conservativeDefault, events: events, tasks: tasks)
        let plan1 = SmartPlanningEngine.makePlan(input)
        let plan2 = SmartPlanningEngine.makePlan(input)
        #expect(plan1.orderedRecommendations.map(\.id) == plan2.orderedRecommendations.map(\.id))
    }
}
