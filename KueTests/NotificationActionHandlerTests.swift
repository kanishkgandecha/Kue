//
//  NotificationActionHandlerTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze": the snooze action's actual
//  behavior, isolated to `NotificationActionHandler.snoozedRequest(from:)` — the pure function
//  `handle`'s snooze branch delegates to. `UNNotificationResponse` has no public initializer,
//  so the full `handle(response:...)` path can't be driven directly from a test; this is
//  exactly why that function was split out (see its own header).
//

import Testing
import Foundation
import UserNotifications
@testable import Kue

@MainActor
struct NotificationActionHandlerTests {
    private func makeRequest(identifier: String = "event-rule-1", snoozeMinutes: Int?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = "Something is due"
        if let snoozeMinutes {
            content.userInfo[NotificationActionIdentifiers.snoozeMinutesUserInfoKey] = snoozeMinutes
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    @Test func snoozingReschedulesTheSameIdentifierWithTheSameContent() {
        let request = makeRequest(snoozeMinutes: 15)
        let snoozed = NotificationActionHandler.snoozedRequest(from: request)
        #expect(snoozed?.identifier == request.identifier)
        #expect(snoozed?.content.title == "Reminder")
        #expect(snoozed?.content.body == "Something is due")
    }

    @Test func snoozingUsesTheExactMinutesFromUserInfoAsTheNewTriggerInterval() {
        let request = makeRequest(snoozeMinutes: 15)
        let snoozed = NotificationActionHandler.snoozedRequest(from: request)
        let trigger = snoozed?.trigger as? UNTimeIntervalNotificationTrigger
        // `UNTimeIntervalNotificationTrigger` rounds its stored `timeInterval` to whole
        // seconds internally — compare with a small tolerance rather than exact equality.
        #expect(abs((trigger?.timeInterval ?? 0) - 15 * 60) < 1)
        #expect(trigger?.repeats == false)
    }

    /// "Test disabled/missing snooze configuration": a request that was never tagged with a
    /// snooze duration at all (e.g. a default-layer candidate, or an older pending request
    /// scheduled before this completion pass shipped) produces no reschedule whatsoever —
    /// never a same-instant or zero-duration one.
    @Test func aRequestWithNoSnoozeMinutesInUserInfoProducesNoReschedule() {
        let request = makeRequest(snoozeMinutes: nil)
        #expect(NotificationActionHandler.snoozedRequest(from: request) == nil)
    }

    @Test func aNonPositiveSnoozeMinutesValueProducesNoReschedule() {
        let request = makeRequest(snoozeMinutes: 0)
        #expect(NotificationActionHandler.snoozedRequest(from: request) == nil)
    }

    @Test func snoozingTwiceProducesTheSameDeterministicIdentifierBothTimes() {
        let request = makeRequest(identifier: "stable-id", snoozeMinutes: 10)
        let first = NotificationActionHandler.snoozedRequest(from: request)
        let second = NotificationActionHandler.snoozedRequest(from: first!)
        #expect(first?.identifier == "stable-id")
        #expect(second?.identifier == "stable-id")
    }

    // MARK: - Scheduling behavior (via the scheduler a real `snooze(response:scheduler:)` would use)

    @Test func addingASnoozedRequestReplacesAnyExistingPendingRequestWithTheSameIdentifier() async {
        let scheduler = FakeNotificationScheduler()
        await scheduler.add(makeRequest(identifier: "x", snoozeMinutes: 10))
        let snoozed = NotificationActionHandler.snoozedRequest(from: makeRequest(identifier: "x", snoozeMinutes: 10))!
        await scheduler.add(snoozed)
        // Deterministic identifier + scoped reconciliation: exactly one pending request for
        // "x", never a duplicate — the same guarantee `NotificationExecutor.reconcile` relies
        // on for its own diff-based add/replace.
        #expect(scheduler.addedRequests.filter { $0.identifier == "x" }.count == 1)
    }
}
