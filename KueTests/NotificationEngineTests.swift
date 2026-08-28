//
//  NotificationEngineTests.swift
//  KueTests
//
//  See docs/08-notifications.md "Scheduling model" / "Pending-notification limit" /
//  "Permission handling". Requirement 11: dedup, edits, cleanup, cap prioritization,
//  immediate far-future scheduling, replenishment, denied permission — end to end through
//  `NotificationEngine.reschedule` against an in-memory `ModelContext` and
//  `FakeNotificationScheduler`. No live `UNUserNotificationCenter` anywhere.
//

import Testing
import Foundation
import SwiftData
import UserNotifications
@testable import Kue

@MainActor
struct NotificationEngineTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func insertEvent(
        in context: ModelContext,
        title: String = "Interview",
        eventType: EventType = .interview,
        startDate: Date
    ) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        context.insert(event)
        let widgetConfiguration = WidgetConfiguration(event: event, widgetType: .preparation)
        context.insert(widgetConfiguration)
        event.widgetConfiguration = widgetConfiguration
        try? context.save()
        return event
    }

    // MARK: - Immediate far-future scheduling (requirement 3)

    @Test func reschedulesAnEventCreatedMonthsOutImmediately() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(60 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))

        #expect(scheduler.addedIdentifiers.contains("\(event.id)-preparation"))
    }

    // MARK: - Deduplication

    @Test func reschedulingTwiceWithNoChangesProducesNoDuplicateIdentifiers() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))

        let identifiers = scheduler.addedIdentifiers
        #expect(Set(identifiers).count == identifiers.count)
    }

    // MARK: - Edits (requirement 4 — stale identifiers removed before the new timeline lands)

    @Test func editingATasksScheduleRemovesTheOldTasksIdentifierNotJustAddsTheNewOne() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .all, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        let oldTaskIdentifiers = event.tasks.map { "\(event.id)-task-\($0.id.uuidString)" }
        #expect(!oldTaskIdentifiers.isEmpty)
        for id in oldTaskIdentifiers { #expect(scheduler.addedIdentifiers.contains(id)) }

        // Same pattern EventFormView.save()/EditScheduleView.save() follow: capture prior
        // identifiers before regenerating (which deletes the old, non-completed tasks and
        // creates fresh ones with new UUIDs), remove them, then reschedule.
        let staleIdentifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        event.startDate = now.addingTimeInterval(20 * 86_400) // moves every task's due date
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        scheduler.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        await NotificationEngine.reschedule(context: context, intensity: .all, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))

        for id in oldTaskIdentifiers {
            #expect(!scheduler.addedIdentifiers.contains(id))
        }
        let newTaskIdentifiers = event.tasks.map { "\(event.id)-task-\($0.id.uuidString)" }
        for id in newTaskIdentifiers { #expect(scheduler.addedIdentifiers.contains(id)) }
    }

    // MARK: - Cleanup (requirement 5)

    @Test func archivingAnEventRemovesEverythingOnTheNextReschedule() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        #expect(!scheduler.addedIdentifiers.isEmpty)

        event.status = .archived
        try? context.save()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        #expect(scheduler.addedIdentifiers.isEmpty)
    }

    // MARK: - Cap prioritization (requirement 6)

    @Test func onlyTheNearest64SurviveWhenTheCapIsThreatened() async {
        let context = makeContext()
        // 70 independent events, `.minimal` intensity. Kue 2.0 Phase 10.1 — docs/25 "J.":
        // `.minimal` now keeps every tier-0 category, not just `.today` — each timed event
        // here contributes three (`.today`, `.eventStart`, `.outcomeFollowUp`; `.preEvent` is
        // explicitly off above), so rather than hand-deriving the exact per-event cutoff, this
        // asserts against the same prioritization Kue itself uses: exactly the cap's worth of
        // candidates survive, and they're precisely the nearest-dated ones.
        var events: [KueEvent] = []
        for i in 0..<70 {
            let event = insertEvent(in: context, title: "Event \(i)", eventType: .exam, startDate: now.addingTimeInterval(Double(100 + i) * 86_400))
            events.append(event)
        }
        try? context.save()

        let noPreEvent = ReminderPreference(preEventMinutes: nil)
        let expectedSurvivors = Set(NotificationCandidateBuilder.prioritized(
            NotificationCandidateBuilder.filter(
                events.flatMap { NotificationCandidateBuilder.candidates(for: $0, now: now, reminderPreference: noPreEvent) },
                intensity: .minimal
            )
        ).prefix(NotificationEngine.pendingRequestCap).map(\.identifier))

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now, reminderPreference: noPreEvent)

        #expect(scheduler.addedIdentifiers.count == NotificationEngine.pendingRequestCap)
        #expect(Set(scheduler.addedIdentifiers) == expectedSurvivors)
        // The furthest-out event is trimmed entirely; the nearest is fully kept.
        #expect(!scheduler.addedIdentifiers.contains("\(events[69].id)-today"))
        #expect(scheduler.addedIdentifiers.contains("\(events[0].id)-today"))
    }

    // MARK: - Replenishment (requirement 6/7)

    @Test func trimmedCandidatesComeBackOnceBudgetFrees() async {
        let context = makeContext()
        var events: [KueEvent] = []
        for i in 0..<70 {
            let event = insertEvent(in: context, title: "Event \(i)", eventType: .exam, startDate: now.addingTimeInterval(Double(100 + i) * 86_400))
            events.append(event)
        }
        try? context.save()

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        #expect(!scheduler.addedIdentifiers.contains("\(events[69].id)-today"))

        // Budget frees up — some events are removed entirely (simulating them completing).
        // Kue 2.0 Phase 10.1 — docs/25 "J.": each event now contributes three tier-0
        // candidates (`.today`, `.eventStart`, `.outcomeFollowUp`), so deleting 50 (not 10) is
        // what actually gets the remaining 20 events' 60 candidates under the 64 cap.
        for event in events[0..<50] { context.delete(event) }
        try? context.save()

        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil))
        #expect(scheduler.addedIdentifiers.contains("\(events[69].id)-today"))
        #expect(scheduler.addedIdentifiers.contains("\(events[69].id)-event-start"))
        #expect(scheduler.addedIdentifiers.contains("\(events[69].id)-outcome-follow-up"))
    }

    // MARK: - Permission handling (requirement 9)

    @Test func deniedPermissionSchedulesNothingAndDoesNotCrash() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationStatusToReturn = .denied
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, requestPermissionIfNeeded: true, reminderPreference: ReminderPreference(preEventMinutes: nil))

        #expect(scheduler.addedIdentifiers.isEmpty)
        #expect(scheduler.requestAuthorizationCallCount == 0) // already-decided states never re-prompt
    }

    @Test func notDeterminedWithoutRequestFlagSchedulesNothingAndNeverPrompts() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationStatusToReturn = .notDetermined
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, reminderPreference: ReminderPreference(preEventMinutes: nil)) // requestPermissionIfNeeded defaults false

        #expect(scheduler.addedIdentifiers.isEmpty)
        #expect(scheduler.requestAuthorizationCallCount == 0)
    }

    @Test func notDeterminedWithRequestFlagPromptsThenSchedulesIfGranted() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationStatusToReturn = .notDetermined
        scheduler.requestAuthorizationResult = true
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, requestPermissionIfNeeded: true, reminderPreference: ReminderPreference(preEventMinutes: nil))

        #expect(scheduler.requestAuthorizationCallCount == 1)
        #expect(!scheduler.addedIdentifiers.isEmpty)
    }
}
