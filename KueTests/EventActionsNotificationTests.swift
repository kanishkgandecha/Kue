//
//  EventActionsNotificationTests.swift
//  KueTests
//
//  See docs/08-notifications.md "Deduplication": "Completing or cancelling an event removes
//  *all* of its pending requests, not just one transition's ... unconditionally." Requirement
//  5, exercised through `EventActions` itself (not `NotificationEngine` directly), since
//  that's the real call path every UI action goes through.
//

import Testing
import Foundation
import SwiftData
import UserNotifications
@testable import Kue

@MainActor
struct EventActionsNotificationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func insertScheduledEvent(in context: ModelContext) async -> (KueEvent, FakeNotificationScheduler) {
        let event = KueEvent(
            title: "Interview",
            eventType: .interview,
            startDate: now.addingTimeInterval(10 * 86_400),
            estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        // Seed as if a prior `reschedule()` had already run for this event.
        for identifier in NotificationCandidateBuilder.allIdentifiers(for: event) {
            let content = UNMutableNotificationContent()
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            await scheduler.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
        return (event, scheduler)
    }

    @Test func cancelRemovesEveryPendingIdentifierUnconditionally() async {
        let context = makeContext()
        let (event, scheduler) = await insertScheduledEvent(in: context)

        EventActions.cancel(event, context: context, now: now, scheduler: scheduler)

        let allIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: event))
        let removed = Set(scheduler.allRemovedIdentifiers)
        #expect(allIdentifiers.isSubset(of: removed))
    }

    @Test func completeRemovesEveryPendingIdentifierUnconditionally() async {
        let context = makeContext()
        let (event, scheduler) = await insertScheduledEvent(in: context)

        EventActions.complete(event, context: context, now: now, scheduler: scheduler)

        let allIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: event))
        let removed = Set(scheduler.allRemovedIdentifiers)
        #expect(allIdentifiers.isSubset(of: removed))
    }

    @Test func archiveRemovesEveryPendingIdentifierUnconditionally() async {
        let context = makeContext()
        let (event, scheduler) = await insertScheduledEvent(in: context)

        EventActions.archive(event, context: context, now: now, scheduler: scheduler)

        let allIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: event))
        let removed = Set(scheduler.allRemovedIdentifiers)
        #expect(allIdentifiers.isSubset(of: removed))
    }

    @Test func deleteRemovesEveryPendingIdentifierEvenThoughTheEventIsGoneAfterward() async {
        let context = makeContext()
        let (event, scheduler) = await insertScheduledEvent(in: context)
        let allIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: event))

        EventActions.delete(event, context: context, scheduler: scheduler)

        let removed = Set(scheduler.allRemovedIdentifiers)
        #expect(allIdentifiers.isSubset(of: removed))
    }

    @Test func uncancelReschedulesTheRevivedEvent() async {
        let context = makeContext()
        let event = KueEvent(
            title: "Interview",
            eventType: .interview,
            startDate: now.addingTimeInterval(10 * 86_400),
            estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC",
            source: .manual,
            isCancelled: true,
            cancelledAt: now
        )
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)

        let scheduler = FakeNotificationScheduler()
        await EventActions.uncancel(event, context: context, now: now, scheduler: scheduler)

        #expect(!scheduler.addedIdentifiers.isEmpty)
        #expect(event.isCancelled == false)
    }
}
