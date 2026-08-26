//
//  SchedulingEngine.swift
//  Kue
//
//  See docs/05-scheduling-engine.md. `plan(...)` and everything above the "Persistence"
//  mark are pure Foundation — no SwiftData, no SwiftUI, independently testable with plain
//  values. `regenerateTasks(for:context:now:)` is the thin layer that applies a plan to the
//  actual model graph, same split EventStatusEngine.swift uses for derive()/reconcile().
//
//  Exam chapter/coverage pacing is explicitly not implemented — docs/04-event-types.md's
//  "coverage" field is an open question (docs/14-open-questions.md); V1 uses the fixed
//  Exam offsets from the table below regardless of coverage.
//

import Foundation
import SwiftData

/// One task the engine has decided should exist, before it's turned into a `KueTask`.
struct ScheduledTaskPlan: Equatable {
    var title: String
    var dueDate: Date
    var offsetLabel: String
    /// True when this slot absorbed one or more dropped-as-past-due offsets — see
    /// "Backward-scheduling clamp" below. Exposed for tests; the compression is already
    /// baked into `title`.
    var isCompressed: Bool
}

enum SchedulingEngine {
    /// docs/07-widget-engine.md's `SnoozeTaskIntent` uses the same 15-minute floor for "is
    /// this due date meaningfully in the future"; reused here for the backward-scheduling
    /// clamp so both places agree on what "too soon to bother with" means.
    static let minimumLeadTime: TimeInterval = 15 * 60

    /// docs/05-scheduling-engine.md "Custom schedule validation" — default max offset.
    static let maxOffsetDays = 90

    // MARK: - Built-in rule templates (docs/05-scheduling-engine.md "Rule templates by event type")

    static func templateType(for eventType: EventType) -> ScheduleTemplateType {
        switch eventType {
        case .generic: return .generic
        case .deadline: return .deadline
        case .exam: return .exam
        case .interview: return .interview
        case .trip: return .trip
        }
    }

    static func defaultRules(for eventType: EventType) -> [ScheduleRule] {
        switch eventType {
        case .interview:
            return [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Preparation start", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 3), taskTitle: "Technical review", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Project/resume review", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(hour: 1), taskTitle: "Final reminder", isTimeSensitive: true),
            ]
        case .exam:
            // Fixed offsets only — no chapter/coverage-aware pacing. See file header.
            return [
                ScheduleRule(offset: DateComponents(day: 14), taskTitle: "Preparation start", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Progress check", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 3), taskTitle: "Revision", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Final revision", isTimeSensitive: false),
            ]
        case .trip:
            return [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Countdown start", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Packing", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(hour: 3), taskTitle: "Departure", isTimeSensitive: true),
            ]
        case .deadline:
            return [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Progress", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 3), taskTitle: "Warning", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Urgent", isTimeSensitive: false),
            ]
        case .generic:
            // "generic copy, no type-specific task titles" — same title at every offset;
            // offsetLabel is what actually distinguishes the three tasks.
            return [
                ScheduleRule(offset: DateComponents(day: 7), taskTitle: "Reminder", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 3), taskTitle: "Reminder", isTimeSensitive: false),
                ScheduleRule(offset: DateComponents(day: 1), taskTitle: "Reminder", isTimeSensitive: false),
            ]
        }
    }

    // MARK: - Custom schedule validation (docs/05-scheduling-engine.md "Custom schedule validation")

    /// Rejects an offset beyond `maxOffsetDays`. Not wired to any UI yet (Edit Schedule is
    /// Phase 6) but the rule must exist now so custom rules — whenever they're entered —
    /// can't bypass it just because Phase 6 hasn't shipped.
    static func isOffsetWithinMaximum(_ offset: DateComponents) -> Bool {
        totalDays(offset) <= Double(maxOffsetDays)
    }

    private static func totalDays(_ offset: DateComponents) -> Double {
        Double(offset.day ?? 0)
            + Double(offset.hour ?? 0) / 24
            + Double(offset.minute ?? 0) / 1_440
            + Double(offset.second ?? 0) / 86_400
    }

    // MARK: - Pure planning (docs/05-scheduling-engine.md "Algorithm" / "Edge cases")

    /// The whole engine, as a pure function: given an event's own date fields and a rule
    /// set, produces the tasks that should exist right now. Calling this twice with
    /// identical inputs always returns identical output (docs/05-scheduling-engine.md's
    /// determinism requirement) — no SwiftData, no randomness, no hidden state.
    static func plan(
        startDate: Date,
        timeZoneIdentifier: String,
        isAllDay: Bool,
        eventType: EventType,
        rules: [ScheduleRule],
        now: Date = .now
    ) -> [ScheduledTaskPlan] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current

        // Time-sensitive rules are skipped entirely for all-day events, not resolved
        // against a fabricated time of day — docs/03-data-model.md "All-day events".
        let applicableRules = isAllDay ? rules.filter { !$0.isTimeSensitive } : rules

        let candidates: [(date: Date, rule: ScheduleRule)] = applicableRules.compactMap { rule in
            guard let date = calendar.date(byAdding: negated(rule.offset), to: startDate) else { return nil }
            return (date, rule)
        }

        // Backward-scheduling clamp: drop anything that wouldn't leave at least
        // `minimumLeadTime` of actual notice.
        let earliestValid = now.addingTimeInterval(minimumLeadTime)
        let survivors = candidates.filter { $0.date >= earliestValid }.sorted { $0.date < $1.date }
        let droppedAny = survivors.count < candidates.count

        return survivors.enumerated().map { index, candidate in
            let isCompressed = droppedAny && index == 0
            let title = isCompressed
                ? compressedTitle(eventType: eventType, dueDate: candidate.date, now: now, calendar: calendar)
                : candidate.rule.taskTitle
            return ScheduledTaskPlan(
                title: title,
                dueDate: candidate.date,
                offsetLabel: offsetLabel(candidate.rule.offset),
                isCompressed: isCompressed
            )
        }
    }

    /// docs/05-scheduling-engine.md: "the nearest remaining future offset becomes the first
    /// task, retitled to indicate compression (e.g. 'Interview prep — condensed, starts
    /// today')." Only ever applied to the earliest surviving task, and only when something
    /// was actually dropped.
    private static func compressedTitle(eventType: EventType, dueDate: Date, now: Date, calendar: Calendar) -> String {
        let timing = calendar.isDate(dueDate, inSameDayAs: now) ? "starts today" : "starts soon"
        return "\(eventType.displayName) prep — condensed, \(timing)"
    }

    private static func offsetLabel(_ components: DateComponents) -> String {
        if let day = components.day, day > 0 {
            return day == 1 ? "1 day before" : "\(day) days before"
        }
        if let hour = components.hour, hour > 0 {
            return hour == 1 ? "1 hour before" : "\(hour) hours before"
        }
        if let minute = components.minute, minute > 0 {
            return minute == 1 ? "1 minute before" : "\(minute) minutes before"
        }
        return "Before"
    }

    /// `DateComponents` meant as a "before" offset (e.g. `day: 3` = 3 days before) negated
    /// so `Calendar.date(byAdding:to:)` subtracts instead of adds — the doc-mandated way to
    /// do this math (never raw `TimeInterval` subtraction, which breaks across DST).
    private static func negated(_ components: DateComponents) -> DateComponents {
        var result = DateComponents()
        if let year = components.year { result.year = -year }
        if let month = components.month { result.month = -month }
        if let day = components.day { result.day = -day }
        if let hour = components.hour { result.hour = -hour }
        if let minute = components.minute { result.minute = -minute }
        if let second = components.second { result.second = -second }
        return result
    }

    // MARK: - Persistence (touches SwiftData — everything above this line does not)

    /// Regenerates `event.tasks` from `event.schedule.rules`, seeding a default schedule on
    /// first call. Preserves completed tasks untouched, deletes stale non-completed ones,
    /// skips generating a duplicate of a preserved completed task, and saves atomically
    /// (rolling back on failure) — docs/05-scheduling-engine.md "Editing an event after its
    /// schedule is generated".
    @discardableResult
    static func regenerateTasks(for event: KueEvent, context: ModelContext, now: Date = .now) -> Bool {
        let schedule: KueSchedule
        if let existing = event.schedule {
            schedule = existing
            if !schedule.isCustom {
                // Built-in templates track the event's current type; custom rules are the
                // user's own and are never silently overwritten.
                schedule.templateType = templateType(for: event.eventType)
                schedule.rules = defaultRules(for: event.eventType)
                schedule.generatedAt = now
            }
        } else {
            schedule = KueSchedule(
                event: event,
                templateType: templateType(for: event.eventType),
                rules: defaultRules(for: event.eventType),
                generatedAt: now
            )
            context.insert(schedule)
            event.schedule = schedule
        }

        let planned = plan(
            startDate: event.startDate,
            timeZoneIdentifier: event.timeZoneIdentifier,
            isAllDay: event.isAllDay,
            eventType: event.eventType,
            rules: schedule.rules,
            now: now
        )

        let preservedCompleted = event.tasks.filter { $0.isCompleted }
        let preservedKeys = Set(preservedCompleted.map { taskKey(title: $0.title, offsetLabel: $0.offsetLabel) })

        // Eliminate stale generated tasks — every non-completed task is regenerated from
        // scratch, never shifted by a delta.
        for task in event.tasks where !task.isCompleted {
            context.delete(task)
        }
        event.tasks.removeAll { !$0.isCompleted }

        // Avoid duplicates: don't recreate a slot a completed task already occupies.
        for item in planned where !preservedKeys.contains(taskKey(title: item.title, offsetLabel: item.offsetLabel)) {
            let task = KueTask(event: event, title: item.title, dueDate: item.dueDate, offsetLabel: item.offsetLabel)
            context.insert(task)
            event.tasks.append(task)
        }

        for (index, task) in event.tasks.sorted(by: { $0.dueDate < $1.dueDate }).enumerated() {
            task.sortOrder = index
        }

        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private static func taskKey(title: String, offsetLabel: String) -> String {
        "\(title)|\(offsetLabel)"
    }
}
