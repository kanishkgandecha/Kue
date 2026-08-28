//
//  BackgroundRefreshHandlerTests.swift
//  KueTests
//
//  See docs/08-notifications.md "Replenishment" and docs/04-event-types.md "Reconciliation"
//  point 2. Requirement 7/10/11: the `BGAppRefreshTask` handler, exercised entirely through
//  fakes — never a real `BGTask`/`BGTaskScheduler`/`UNUserNotificationCenter`.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct BackgroundRefreshHandlerTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func handleResubmitsTheNextOpportunityAndCompletesSuccessfully() async {
        let context = makeContext()
        let task = FakeBackgroundTask()
        let notificationScheduler = FakeNotificationScheduler()
        let backgroundScheduler = FakeBackgroundTaskScheduler()

        await BackgroundRefreshHandler.handle(
            task,
            context: context,
            scheduler: notificationScheduler,
            backgroundScheduler: backgroundScheduler
        )

        #expect(backgroundScheduler.submittedIdentifiers == [BackgroundRefreshTask.identifier])
        #expect(task.completedSuccess == true)
    }

    @Test func handleRunsTheReconciliationSweep() async {
        let context = makeContext()
        // A completed-but-still-`.upcoming`-tagged event — the sweep should reconcile it.
        let event = KueEvent(
            title: "Past deadline",
            eventType: .deadline,
            startDate: Date(timeIntervalSince1970: 1_000_000),
            estimatedDurationMinutes: 0,
            timeZoneIdentifier: "UTC",
            source: .manual,
            status: .upcoming
        )
        context.insert(event)
        try? context.save()

        // One day after startDate — past `effectiveEndDate` (a 0-duration deadline reaches its
        // end instantly), so the sweep should reconcile the stale `.upcoming` tag to Awaiting
        // Outcome (Kue 2.0 Phase 10.1 — docs/25 "C.": passing time alone never lands on
        // `.completed`, and never auto-archives from here either).
        await BackgroundRefreshHandler.handle(
            FakeBackgroundTask(),
            context: context,
            scheduler: FakeNotificationScheduler(),
            backgroundScheduler: FakeBackgroundTaskScheduler(),
            now: Date(timeIntervalSince1970: 1_000_000 + 86_400)
        )

        #expect(event.status == .awaitingOutcome)
    }

    @Test func handleReplenishesNotificationsWhenAuthorized() async {
        let context = makeContext()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
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

        let notificationScheduler = FakeNotificationScheduler()
        await BackgroundRefreshHandler.handle(
            FakeBackgroundTask(),
            context: context,
            scheduler: notificationScheduler,
            backgroundScheduler: FakeBackgroundTaskScheduler(),
            now: now
        )

        #expect(!notificationScheduler.addedIdentifiers.isEmpty)
        // Passive trigger — never prompts, even when permission is still undetermined.
        #expect(notificationScheduler.requestAuthorizationCallCount == 0)
    }

    @Test func handleStopsEarlyOnExpirationWithoutCrashing() async {
        let context = makeContext()

        // Simulate iOS revoking background time mid-run by expiring immediately once the
        // handler installs its expiration closure — the handler is expected to check this
        // and bail out before doing further work.
        final class ExpiringTask: BackgroundTaskExecuting {
            var expirationHandler: (() -> Void)? {
                didSet { expirationHandler?() }
            }
            private(set) var completedSuccess: Bool?
            func setTaskCompleted(success: Bool) { completedSuccess = success }
        }
        let expiringTask = ExpiringTask()

        await BackgroundRefreshHandler.handle(
            expiringTask,
            context: context,
            scheduler: FakeNotificationScheduler(),
            backgroundScheduler: FakeBackgroundTaskScheduler()
        )

        #expect(expiringTask.completedSuccess == false)
    }
}
