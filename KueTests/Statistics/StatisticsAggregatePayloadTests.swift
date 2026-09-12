//
//  StatisticsAggregatePayloadTests.swift
//  KueTests
//
//  Kue 3.0 Phase 6 — docs/34 "Exact aggregate fields uploaded." Proves the upload shape is
//  built only from `ProfileStatistics`' own already-aggregate fields, round-trips through
//  JSON with the exact snake_case keys the SQL migration's columns use, and never carries an
//  event/task title, note, location, or identifier.
//

import Testing
import Foundation
@testable import Kue

struct StatisticsAggregatePayloadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func makeCopiesEveryAggregateFieldFromProfileStatistics() {
        var statistics = ProfileStatistics.empty
        statistics.totalActiveEvents = 3
        statistics.completedEvents = 2
        statistics.cancelledEvents = 1
        statistics.skippedEvents = 1
        statistics.eventsNeedingReview = 1
        statistics.completedTasks = 5
        statistics.pendingTasks = 4
        statistics.completionRate = 0.55
        statistics.upcoming7Days = 2
        statistics.upcoming30Days = 6
        statistics.preparationWorkload = 3
        statistics.currentCompletionStreak = 2
        statistics.longestCompletionStreak = 5
        statistics.averageTaskCompletionLeadTimeHours = -1.5

        let calendar = Calendar(identifier: .gregorian)
        let bucketStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let payload = StatisticsAggregatePayload.make(from: statistics, bucketStart: bucketStart, calendar: calendar)

        #expect(payload.totalActiveEvents == 3)
        #expect(payload.completedEvents == 2)
        #expect(payload.cancelledEvents == 1)
        #expect(payload.skippedEvents == 1)
        #expect(payload.eventsNeedingReview == 1)
        #expect(payload.completedTasks == 5)
        #expect(payload.pendingTasks == 4)
        #expect(payload.taskCompletionRate == 0.55)
        #expect(payload.upcoming7Days == 2)
        #expect(payload.upcoming30Days == 6)
        #expect(payload.preparationWorkload == 3)
        #expect(payload.currentStreak == 2)
        #expect(payload.longestStreak == 5)
        #expect(payload.avgTaskCompletionLeadTimeHours == -1.5)
    }

    @Test func bucketStartFormatsAsABareCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: 2026, month: 3, day: 2) // a Monday
        let monday = calendar.date(from: components)!
        let payload = StatisticsAggregatePayload.make(from: .empty, bucketStart: monday, calendar: calendar)
        #expect(payload.bucketStart == "2026-03-02")
    }

    @Test func nilOptionalFieldsRoundTripThroughJSONAsNullNeverAnInventedZero() throws {
        let payload = StatisticsAggregatePayload.make(from: .empty, bucketStart: now, calendar: .current)
        #expect(payload.taskCompletionRate == nil)
        #expect(payload.currentStreak == nil)
        #expect(payload.longestStreak == nil)
        #expect(payload.avgTaskCompletionLeadTimeHours == nil)

        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Swift's synthesized `Codable` encodes a `nil` Optional as an explicit JSON `null`
        // (never omits the key) — this is what tells PostgREST to store SQL `NULL`, the same
        // "not enough data" honesty `ProfileStatistics` itself already carries, never a
        // silently-substituted `0`.
        #expect(json?["task_completion_rate"] is NSNull)
        let decoded = try JSONDecoder().decode(StatisticsAggregatePayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func encodedPayloadContainsOnlyTheExpectedSnakeCaseKeysNeverContent() throws {
        var statistics = ProfileStatistics.empty
        statistics.totalActiveEvents = 1
        let payload = StatisticsAggregatePayload.make(from: statistics, bucketStart: now, calendar: .current)
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let expectedKeys: Set<String> = [
            "bucket_start", "total_active_events", "completed_events", "cancelled_events",
            "skipped_events", "events_needing_review", "completed_tasks", "pending_tasks",
            "task_completion_rate", "upcoming_7_days", "upcoming_30_days", "preparation_workload",
            "current_streak", "longest_streak", "avg_task_completion_lead_time_hours",
        ]
        #expect(Set(json.keys) == expectedKeys)
    }
}
