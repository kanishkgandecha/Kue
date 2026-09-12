//
//  StatisticsAggregatePayload.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Exact aggregate fields uploaded." The one, deliberately narrow
//  shape ever sent to Supabase's `statistics_aggregates` table (see that migration's own
//  header) — every field here is a plain count/rate/hours value already present on
//  `ProfileStatistics`; nothing here is an event/task title, note, location, OCR/voice
//  transcript, Calendar identifier, or event/task UUID (requirement A). Deliberately excludes
//  `ProfileStatistics.countsByEventType`/`completedCountsByEventType`/`nearestUpcomingEvent`/
//  `weeklyActivity` — meaningful as instantaneous local facts, not worth a server-side column
//  set of their own (requirement D: "deliberately selected aggregate values," never a raw
//  dump of everything the local engine happens to know).
//
//  `make(from:bucketStart:)` is the *only* place this shape is ever produced — never
//  hand-assembled at a call site — so the upload payload can never silently drift from what
//  `ProfileStatisticsEngine` actually computed.
//

import Foundation

nonisolated struct StatisticsAggregatePayload: Equatable {
    /// This ISO week's Monday, as a bare calendar day (`yyyy-MM-dd`, no time-of-day, no
    /// offset) — matches the migration's own `bucket_start date` column exactly.
    var bucketStart: String
    var totalActiveEvents: Int
    var completedEvents: Int
    var cancelledEvents: Int
    var skippedEvents: Int
    var eventsNeedingReview: Int
    var completedTasks: Int
    var pendingTasks: Int
    var taskCompletionRate: Double?
    var upcoming7Days: Int
    var upcoming30Days: Int
    var preparationWorkload: Int
    var currentStreak: Int?
    var longestStreak: Int?
    var avgTaskCompletionLeadTimeHours: Double?

    private enum CodingKeys: String, CodingKey {
        case bucketStart = "bucket_start"
        case totalActiveEvents = "total_active_events"
        case completedEvents = "completed_events"
        case cancelledEvents = "cancelled_events"
        case skippedEvents = "skipped_events"
        case eventsNeedingReview = "events_needing_review"
        case completedTasks = "completed_tasks"
        case pendingTasks = "pending_tasks"
        case taskCompletionRate = "task_completion_rate"
        case upcoming7Days = "upcoming_7_days"
        case upcoming30Days = "upcoming_30_days"
        case preparationWorkload = "preparation_workload"
        case currentStreak = "current_streak"
        case longestStreak = "longest_streak"
        case avgTaskCompletionLeadTimeHours = "avg_task_completion_lead_time_hours"
    }

    /// The one place a `ProfileStatistics` snapshot becomes the narrow shape ever uploaded.
    static func make(from statistics: ProfileStatistics, bucketStart: Date, calendar: Calendar) -> StatisticsAggregatePayload {
        StatisticsAggregatePayload(
            bucketStart: Self.dayString(bucketStart, calendar: calendar),
            totalActiveEvents: statistics.totalActiveEvents,
            completedEvents: statistics.completedEvents,
            cancelledEvents: statistics.cancelledEvents,
            skippedEvents: statistics.skippedEvents,
            eventsNeedingReview: statistics.eventsNeedingReview,
            completedTasks: statistics.completedTasks,
            pendingTasks: statistics.pendingTasks,
            taskCompletionRate: statistics.completionRate,
            upcoming7Days: statistics.upcoming7Days,
            upcoming30Days: statistics.upcoming30Days,
            preparationWorkload: statistics.preparationWorkload,
            currentStreak: statistics.currentCompletionStreak,
            longestStreak: statistics.longestCompletionStreak,
            avgTaskCompletionLeadTimeHours: statistics.averageTaskCompletionLeadTimeHours
        )
    }

    /// `calendar`'s own week-start instant, formatted as the bare `yyyy-MM-dd` the SQL `date`
    /// column expects — computed in `calendar`'s own time zone so the day this represents to
    /// the user is never shifted by a UTC round-trip.
    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        return formatter.string(from: date)
    }
}

extension StatisticsAggregatePayload: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketStart = try container.decode(String.self, forKey: .bucketStart)
        totalActiveEvents = try container.decode(Int.self, forKey: .totalActiveEvents)
        completedEvents = try container.decode(Int.self, forKey: .completedEvents)
        cancelledEvents = try container.decode(Int.self, forKey: .cancelledEvents)
        skippedEvents = try container.decode(Int.self, forKey: .skippedEvents)
        eventsNeedingReview = try container.decode(Int.self, forKey: .eventsNeedingReview)
        completedTasks = try container.decode(Int.self, forKey: .completedTasks)
        pendingTasks = try container.decode(Int.self, forKey: .pendingTasks)
        taskCompletionRate = try container.decodeIfPresent(Double.self, forKey: .taskCompletionRate)
        upcoming7Days = try container.decode(Int.self, forKey: .upcoming7Days)
        upcoming30Days = try container.decode(Int.self, forKey: .upcoming30Days)
        preparationWorkload = try container.decode(Int.self, forKey: .preparationWorkload)
        currentStreak = try container.decodeIfPresent(Int.self, forKey: .currentStreak)
        longestStreak = try container.decodeIfPresent(Int.self, forKey: .longestStreak)
        avgTaskCompletionLeadTimeHours = try container.decodeIfPresent(Double.self, forKey: .avgTaskCompletionLeadTimeHours)
    }

    /// A custom `encode(to:)`, not the synthesized one — Foundation's default `Encoder`
    /// machinery *omits* the key entirely for a `nil` Optional value rather than emitting an
    /// explicit JSON `null` (confirmed by this file's own test suite). That distinction matters
    /// here: PostgREST's upsert (`Prefer: resolution=merge-duplicates`) only touches the
    /// columns actually present in the request body, so an *omitted* key on a re-upload would
    /// silently leave a stale previous value in place instead of correctly clearing it back to
    /// SQL `NULL` when a statistic genuinely becomes "not enough data" again. `encodeNil` makes
    /// every nullable field explicit on every upload, always reflecting the current snapshot.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bucketStart, forKey: .bucketStart)
        try container.encode(totalActiveEvents, forKey: .totalActiveEvents)
        try container.encode(completedEvents, forKey: .completedEvents)
        try container.encode(cancelledEvents, forKey: .cancelledEvents)
        try container.encode(skippedEvents, forKey: .skippedEvents)
        try container.encode(eventsNeedingReview, forKey: .eventsNeedingReview)
        try container.encode(completedTasks, forKey: .completedTasks)
        try container.encode(pendingTasks, forKey: .pendingTasks)
        try encodeNullable(taskCompletionRate, forKey: .taskCompletionRate, in: &container)
        try container.encode(upcoming7Days, forKey: .upcoming7Days)
        try container.encode(upcoming30Days, forKey: .upcoming30Days)
        try container.encode(preparationWorkload, forKey: .preparationWorkload)
        try encodeNullable(currentStreak, forKey: .currentStreak, in: &container)
        try encodeNullable(longestStreak, forKey: .longestStreak, in: &container)
        try encodeNullable(avgTaskCompletionLeadTimeHours, forKey: .avgTaskCompletionLeadTimeHours, in: &container)
    }

    private func encodeNullable<T: Encodable>(_ value: T?, forKey key: CodingKeys, in container: inout KeyedEncodingContainer<CodingKeys>) throws {
        if let value { try container.encode(value, forKey: key) } else { try container.encodeNil(forKey: key) }
    }
}
