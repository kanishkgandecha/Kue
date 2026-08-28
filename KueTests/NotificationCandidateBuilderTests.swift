//
//  NotificationCandidateBuilderTests.swift
//  KueTests
//
//  See docs/08-notifications.md "Notification categories" / "Deduplication" / "Pending-
//  notification limit". Pure — no SwiftData context, no scheduler, same style as
//  WidgetContentServiceTests (this builder consumes the exact same transitionPlan).
//

import Testing
import Foundation
@testable import Kue

struct NotificationCandidateBuilderTests {
    private func makeEvent(
        title: String = "Interview",
        eventType: EventType = .interview,
        startDate: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        isManuallyCompleted: Bool = false,
        status: EventStatus = .upcoming
    ) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            estimatedDurationMinutes: 60,
            isAllDay: isAllDay,
            timeZoneIdentifier: "UTC",
            source: .manual,
            priority: .medium,
            status: status,
            isCancelled: isCancelled,
            isManuallyCompleted: isManuallyCompleted
        )
        return event
    }

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    // MARK: - Dates (candidates line up with WidgetContentService.transitionPlan)

    @Test func candidateDatesMatchTheWidgetEnginesTransitionPlan() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now)
        let plan = Dictionary(uniqueKeysWithValues: WidgetContentService.transitionPlan(for: event, now: now).map { ($0.phase, $0.date) })

        #expect(candidates.first { $0.kind == .preparationStart }?.fireDate == plan[.preparation])
        #expect(candidates.first { $0.kind == .tomorrow }?.fireDate == plan[.tomorrow])
        #expect(candidates.first { $0.kind == .today }?.fireDate == plan[.today])
    }

    // MARK: - Kue 2.0 Phase 3 — skip (docs/17-recurring-events.md "Occurrence actions")

    @Test func skippedOccurrenceProducesNoCandidates() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.isSkipped = true
        #expect(NotificationCandidateBuilder.candidates(for: event, now: now).isEmpty)
    }

    @Test func taskDueCandidateDateMatchesTheTasksOwnDueDate() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Review", dueDate: now.addingTimeInterval(5 * 86_400), offsetLabel: "5 days before")
        event.tasks = [task]
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now)
        #expect(candidates.first { $0.kind == .taskDue(taskID: task.id) }?.fireDate == task.dueDate)
    }

    // MARK: - Immediate far-future scheduling (requirement 3 — no date-window gate)

    @Test func aFarFutureEventStillProducesCandidatesImmediately() {
        // Two months out — nowhere near iOS's rolling-window era this doc explicitly rejects.
        let event = makeEvent(startDate: now.addingTimeInterval(60 * 86_400))
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now)
        #expect(!candidates.isEmpty)
        #expect(candidates.contains { $0.kind == .preparationStart })
    }

    // MARK: - Identifiers (requirement 2 — exact eventID-transitionKind format)

    @Test func identifierFormatMatchesTheDocumentedShape() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 86_400))
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now)
        let tomorrow = candidates.first { $0.kind == .tomorrow }
        #expect(tomorrow?.identifier == "\(event.id)-tomorrow")
    }

    @Test func taskIdentifierFormatMatchesTheDocumentedShape() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Review", dueDate: now.addingTimeInterval(5 * 86_400), offsetLabel: "5 days before")
        event.tasks = [task]
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now).first { $0.kind == .taskDue(taskID: task.id) }
        #expect(candidate?.identifier == "\(event.id)-task-\(task.id.uuidString)")
    }

    @Test func allIdentifiersIsExhaustiveRegardlessOfWhatsCurrentlyScheduled() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Review", dueDate: now.addingTimeInterval(5 * 86_400), offsetLabel: "5 days before")
        event.tasks = [task]
        let all = NotificationCandidateBuilder.allIdentifiers(for: event)
        #expect(all.contains("\(event.id)-preparation"))
        #expect(all.contains("\(event.id)-tomorrow"))
        #expect(all.contains("\(event.id)-today"))
        #expect(all.contains("\(event.id)-task-\(task.id.uuidString)"))
        // Kue 2.0 Phase 10.1 — docs/25 "J.": the three new transition kinds join the
        // exhaustive identifier set too, so editing/cancelling this event reliably clears
        // their stale pending requests as well.
        #expect(all.contains("\(event.id)-pre-event"))
        #expect(all.contains("\(event.id)-event-start"))
        #expect(all.contains("\(event.id)-outcome-follow-up"))
        #expect(all.count == 7)
    }

    // MARK: - Cleanup (requirement 5 — no candidates for events the user no longer cares about)

    @Test func archivedCancelledAndCompletedEventsProduceNoCandidates() {
        let archived = makeEvent(startDate: now.addingTimeInterval(2 * 86_400), status: .archived)
        let cancelled = makeEvent(startDate: now.addingTimeInterval(2 * 86_400), isCancelled: true)
        let completed = makeEvent(startDate: now.addingTimeInterval(2 * 86_400), isManuallyCompleted: true)
        #expect(NotificationCandidateBuilder.candidates(for: archived, now: now).isEmpty)
        #expect(NotificationCandidateBuilder.candidates(for: cancelled, now: now).isEmpty)
        #expect(NotificationCandidateBuilder.candidates(for: completed, now: now).isEmpty)
    }

    // MARK: - Intensity filter

    @Test func minimalIntensityKeepsOnlyTodayUrgentTier() {
        let event = makeEvent(startDate: now.addingTimeInterval(2 * 86_400))
        let all = NotificationCandidateBuilder.candidates(for: event, now: now)
        let filtered = NotificationCandidateBuilder.filter(all, intensity: .minimal)
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0.priorityTier == 0 })
    }

    @Test func standardIntensityExcludesOnlyTaskDue() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Review", dueDate: now.addingTimeInterval(5 * 86_400), offsetLabel: "5 days before")
        event.tasks = [task]
        let all = NotificationCandidateBuilder.candidates(for: event, now: now)
        let filtered = NotificationCandidateBuilder.filter(all, intensity: .standard)
        #expect(filtered.contains { $0.kind == .preparationStart })
        #expect(!filtered.contains { if case .taskDue = $0.kind { return true }; return false })
    }

    @Test func allIntensityKeepsEverythingIncludingTaskDue() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Review", dueDate: now.addingTimeInterval(5 * 86_400), offsetLabel: "5 days before")
        event.tasks = [task]
        let all = NotificationCandidateBuilder.candidates(for: event, now: now)
        let filtered = NotificationCandidateBuilder.filter(all, intensity: .all)
        #expect(filtered.count == all.count)
    }

    // MARK: - Urgent tier for Interview/Deadline at the `.tomorrow` transition

    @Test func interviewTomorrowTransitionIsTopPriorityTierLikeToday() {
        let event = makeEvent(eventType: .interview, startDate: now.addingTimeInterval(2 * 86_400))
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now).first { $0.kind == .tomorrow }
        #expect(candidate?.isUrgentTier == true)
        #expect(candidate?.priorityTier == 0)
    }

    @Test func examTomorrowTransitionIsNotUrgentTier() {
        let event = makeEvent(eventType: .exam, startDate: now.addingTimeInterval(2 * 86_400))
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now).first { $0.kind == .tomorrow }
        #expect(candidate?.isUrgentTier == false)
        #expect(candidate?.priorityTier == 1)
    }

    // MARK: - Priority ordering / cap prioritization (requirement 6)

    @Test func prioritizedSortsByDateAscendingFirstThenTier() {
        let soonLowPriority = NotificationCandidate(
            eventID: UUID(), kind: .preparationStart, fireDate: now.addingTimeInterval(100), isUrgentTier: false, title: "A", body: "A"
        )
        let laterHighPriority = NotificationCandidate(
            eventID: UUID(), kind: .today, fireDate: now.addingTimeInterval(200), isUrgentTier: true, title: "B", body: "B"
        )
        // Date wins over tier: the nearer-but-lower-priority one sorts first.
        let sorted = NotificationCandidateBuilder.prioritized([laterHighPriority, soonLowPriority])
        #expect(sorted.first?.title == "A")
    }

    @Test func prioritizedBreaksSameDayTiesByTier() {
        let sameDate = now.addingTimeInterval(500)
        let tomorrow = NotificationCandidate(eventID: UUID(), kind: .tomorrow, fireDate: sameDate, isUrgentTier: false, title: "Tomorrow", body: "")
        let preparation = NotificationCandidate(eventID: UUID(), kind: .preparationStart, fireDate: sameDate, isUrgentTier: false, title: "Prep", body: "")
        let today = NotificationCandidate(eventID: UUID(), kind: .today, fireDate: sameDate, isUrgentTier: true, title: "Today", body: "")
        let sorted = NotificationCandidateBuilder.prioritized([preparation, tomorrow, today])
        #expect(sorted.map(\.title) == ["Today", "Tomorrow", "Prep"])
    }

    // MARK: - Kue 2.0 Phase 10.1 — docs/25 "H./J." — event-start, pre-event, outcome follow-up

    @Test func eventStartFiresAtTheActualStartInstantForATimedEvent() {
        let start = now.addingTimeInterval(10 * 86_400 + 3_723) // an arbitrary non-midnight time
        let event = makeEvent(startDate: start)
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil)).first { $0.kind == .eventStart }
        #expect(candidate?.fireDate == start)
        #expect(candidate?.body == "Interview is starting now")
        #expect(candidate?.priorityTier == 0) // shown even at .minimal
    }

    @Test func eventStartNeverFiresInThePastForAnAlreadyStartedEvent() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3_600))
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil)).first { $0.kind == .eventStart }
        #expect(candidate == nil)
    }

    @Test func eventStartUsesAPinnedTimezoneMorningReminderForAllDayEventsNotMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let expectedMorning = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let event = makeEvent(startDate: midnight, isAllDay: true)
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil)).first { $0.kind == .eventStart }
        #expect(candidate?.fireDate == expectedMorning)
        #expect(candidate?.body == "Interview is today")
    }

    @Test func preEventIsAbsentWhenThePreferenceIsOff() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        #expect(!candidates.contains { $0.kind == .preEvent })
    }

    @Test func preEventFiresTheConfiguredMinutesBeforeStartDate() {
        let start = now.addingTimeInterval(10 * 86_400)
        let event = makeEvent(startDate: start)
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: 30)).first { $0.kind == .preEvent }
        #expect(candidate?.fireDate == start.addingTimeInterval(-30 * 60))
        #expect(candidate?.body == "Interview starts in 30 minutes")
    }

    @Test func preEventNeverFiresForAllDayEvents() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), isAllDay: true)
        let candidates = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: 30))
        #expect(!candidates.contains { $0.kind == .preEvent })
    }

    @Test func outcomeFollowUpFiresExactlyAtEffectiveEndDateWithHonestCopy() {
        let start = now.addingTimeInterval(10 * 86_400)
        let event = makeEvent(startDate: start)
        let candidate = NotificationCandidateBuilder.candidates(for: event, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil)).first { $0.kind == .outcomeFollowUp }
        #expect(candidate?.fireDate == event.effectiveEndDate)
        #expect(candidate?.body == "How did Interview go?")
        #expect(candidate?.priorityTier == 0) // requirement: never starved by low-priority reminders
    }
}
