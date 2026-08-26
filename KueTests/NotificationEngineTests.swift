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
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now)

        #expect(scheduler.addedIdentifiers.contains("\(event.id)-preparation"))
    }

    // MARK: - Deduplication

    @Test func reschedulingTwiceWithNoChangesProducesNoDuplicateIdentifiers() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now)
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now)

        let identifiers = scheduler.addedIdentifiers
        #expect(Set(identifiers).count == identifiers.count)
    }

    // MARK: - Edits (requirement 4 — stale identifiers removed before the new timeline lands)

    @Test func editingATasksScheduleRemovesTheOldTasksIdentifierNotJustAddsTheNewOne() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .all, scheduler: scheduler, now: now)
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
        await NotificationEngine.reschedule(context: context, intensity: .all, scheduler: scheduler, now: now)

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
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now)
        #expect(!scheduler.addedIdentifiers.isEmpty)

        event.status = .archived
        try? context.save()
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now)
        #expect(scheduler.addedIdentifiers.isEmpty)
    }

    // MARK: - Cap prioritization (requirement 6)

    @Test func onlyTheNearest64SurviveWhenTheCapIsThreatened() async {
        let context = makeContext()
        // 70 independent events, `.minimal` intensity so each contributes exactly one
        // candidate (`.today`, the only tier-0 category) at a distinct, staggered date —
        // isolates the cap/priority logic from having to reason about multiple candidates
        // per event competing at once.
        var events: [KueEvent] = []
        for i in 0..<70 {
            let event = insertEvent(in: context, title: "Event \(i)", eventType: .exam, startDate: now.addingTimeInterval(Double(100 + i) * 86_400))
            events.append(event)
        }
        try? context.save()

        let scheduler = FakeNotificationScheduler()
        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now)

        #expect(scheduler.addedIdentifiers.count == NotificationEngine.pendingRequestCap)
        // The nearest-dated events (0..<64) survive; the furthest-out (64..<70) are trimmed.
        for i in 0..<64 {
            #expect(scheduler.addedIdentifiers.contains("\(events[i].id)-today"))
        }
        for i in 64..<70 {
            #expect(!scheduler.addedIdentifiers.contains("\(events[i].id)-today"))
        }
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
        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now)
        #expect(!scheduler.addedIdentifiers.contains("\(events[69].id)-today"))

        // Budget frees up — some events are removed entirely (simulating them completing).
        for event in events[0..<10] { context.delete(event) }
        try? context.save()

        await NotificationEngine.reschedule(context: context, intensity: .minimal, scheduler: scheduler, now: now)
        #expect(scheduler.addedIdentifiers.contains("\(events[69].id)-today"))
    }

    // MARK: - Permission handling (requirement 9)

    @Test func deniedPermissionSchedulesNothingAndDoesNotCrash() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationStatusToReturn = .denied
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, requestPermissionIfNeeded: true)

        #expect(scheduler.addedIdentifiers.isEmpty)
        #expect(scheduler.requestAuthorizationCallCount == 0) // already-decided states never re-prompt
    }

    @Test func notDeterminedWithoutRequestFlagSchedulesNothingAndNeverPrompts() async {
        let context = makeContext()
        let event = insertEvent(in: context, startDate: now.addingTimeInterval(10 * 86_400))
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationStatusToReturn = .notDetermined
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now) // requestPermissionIfNeeded defaults false

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
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, now: now, requestPermissionIfNeeded: true)

        #expect(scheduler.requestAuthorizationCallCount == 1)
        #expect(!scheduler.addedIdentifiers.isEmpty)
    }
}
