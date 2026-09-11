//
//  NotificationExecutorTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Execution": add, replace, remove,
//  partial failure, repeated idempotent reconciliation, no removal of unrelated requests.
//

import Testing
import Foundation
import UserNotifications
@testable import Kue

@MainActor
struct NotificationExecutorTests {
    private func candidate(identifier: String, eventID: UUID = UUID(), date: Date = .now.addingTimeInterval(3600)) -> NotificationScheduledCandidate {
        NotificationScheduledCandidate(
            identifier: identifier, eventID: eventID, taskID: nil, sourceRuleID: nil,
            title: "Title", body: "Body", requestedDeliveryDate: date, effectiveDeliveryDate: date,
            quietHoursAdjustment: .none, priority: 0, sound: .defaultSound, interruptionPreference: .active,
            explanation: "Test"
        )
    }

    @Test func reconcileAddsEveryScheduledCandidate() async {
        let scheduler = FakeNotificationScheduler()
        let plan = NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "a"), candidate(identifier: "b")], excludedCandidates: [])
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["a", "b"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        #expect(Set(scheduler.addedIdentifiers) == ["a", "b"])
    }

    @Test func reconcileRemovesAKnownIdentifierNoLongerDesired() async {
        let scheduler = FakeNotificationScheduler()
        await scheduler.add(UNNotificationRequest(identifier: "stale", content: .init(), trigger: nil))
        let plan = NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "fresh")], excludedCandidates: [])
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["stale", "fresh"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        #expect(!scheduler.addedIdentifiers.contains("stale"))
        #expect(scheduler.addedIdentifiers.contains("fresh"))
    }

    @Test func reconcileNeverRemovesAPendingIdentifierOutsideItsKnownSet() async {
        // docs/31 "Execution": "No removal of unrelated requests." An identifier the caller
        // didn't declare as "known" (e.g. belonging to a different event's own graph, or in
        // principle a foreign one) must survive even if it isn't in the desired set.
        let scheduler = FakeNotificationScheduler()
        await scheduler.add(UNNotificationRequest(identifier: "unrelated", content: .init(), trigger: nil))
        let plan = NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "fresh")], excludedCandidates: [])
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["fresh"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        #expect(scheduler.addedIdentifiers.contains("unrelated"))
    }

    @Test func reconcileReplacesAnAlreadyPendingIdentifierRatherThanDuplicating() async {
        let scheduler = FakeNotificationScheduler()
        let eventID = UUID()
        let originalDate = Date.now.addingTimeInterval(3600)
        let updatedDate = Date.now.addingTimeInterval(7200)
        await NotificationExecutor.reconcile(
            plan: NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "x", eventID: eventID, date: originalDate)], excludedCandidates: []),
            knownIdentifiers: ["x"], scheduler: scheduler, globalPreferences: .conservativeDefault
        )
        await NotificationExecutor.reconcile(
            plan: NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "x", eventID: eventID, date: updatedDate)], excludedCandidates: []),
            knownIdentifiers: ["x"], scheduler: scheduler, globalPreferences: .conservativeDefault
        )
        #expect(scheduler.addedIdentifiers.filter { $0 == "x" }.count == 1) // FakeNotificationScheduler dedups by identifier, same as a real center
    }

    @Test func repeatedIdempotentReconciliationProducesNoChurn() async {
        let scheduler = FakeNotificationScheduler()
        let plan = NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "a")], excludedCandidates: [])
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["a"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["a"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["a"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        #expect(scheduler.addedIdentifiers == ["a"])
    }

    // MARK: - Partial failure (docs/31 "Execution": "Partial failure")

    @Test func aFailedAddDoesNotPreventOtherCandidatesFromScheduling() async {
        let scheduler = FailureInjectingNotificationScheduler()
        scheduler.identifiersToFail = ["b"]
        let plan = NotificationSchedulePlan(scheduledCandidates: [candidate(identifier: "a"), candidate(identifier: "b"), candidate(identifier: "c")], excludedCandidates: [])
        await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: ["a", "b", "c"], scheduler: scheduler, globalPreferences: .conservativeDefault)
        #expect(Set(scheduler.addedIdentifiers) == ["a", "c"])
    }

    // MARK: - Request content

    @Test func silentSoundProducesNoSoundOnTheRequest() {
        let candidate = candidate(identifier: "silent")
        var silentCandidate = candidate
        silentCandidate.sound = .silent
        let request = NotificationExecutor.makeRequest(for: silentCandidate, globalPreferences: .conservativeDefault)
        #expect(request.content.sound == nil)
    }

    @Test func badgeDisabledLeavesTheBadgeUnset() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.badgeEnabled = false
        let request = NotificationExecutor.makeRequest(for: candidate(identifier: "no-badge"), globalPreferences: preferences)
        #expect(request.content.badge == nil)
    }

    @Test func groupingEnabledSetsTheThreadIdentifierToTheEventID() {
        let eventID = UUID()
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.groupNotificationsByEvent = true
        let request = NotificationExecutor.makeRequest(for: candidate(identifier: "grouped", eventID: eventID), globalPreferences: preferences)
        #expect(request.content.threadIdentifier == eventID.uuidString)
    }

    // MARK: - Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze"

    private func ruleCandidate(identifier: String, snoozeMinutes: Int?, explanation: String = "10 minutes before start") -> NotificationScheduledCandidate {
        NotificationScheduledCandidate(
            identifier: identifier, eventID: UUID(), taskID: nil, sourceRuleID: UUID(),
            title: "Title", body: "Body", requestedDeliveryDate: .now.addingTimeInterval(3600), effectiveDeliveryDate: .now.addingTimeInterval(3600),
            quietHoursAdjustment: .none, priority: 0, sound: .defaultSound, interruptionPreference: .active,
            explanation: explanation, snoozeMinutes: snoozeMinutes
        )
    }

    @Test func aRuleSourcedCandidateWithASnoozeDurationGetsTheSnoozeCategoryAndUserInfo() {
        let request = NotificationExecutor.makeRequest(for: ruleCandidate(identifier: "snoozable", snoozeMinutes: 20), globalPreferences: .conservativeDefault)
        #expect(request.content.categoryIdentifier == NotificationActionIdentifiers.ruleSnoozeCategory)
        #expect(request.content.userInfo[NotificationActionIdentifiers.snoozeMinutesUserInfoKey] as? Int == 20)
    }

    @Test func aDefaultLayerCandidateNeverGetsTheSnoozeCategory() {
        let request = NotificationExecutor.makeRequest(for: candidate(identifier: "default-layer"), globalPreferences: .conservativeDefault)
        #expect(request.content.categoryIdentifier != NotificationActionIdentifiers.ruleSnoozeCategory)
        #expect(request.content.userInfo[NotificationActionIdentifiers.snoozeMinutesUserInfoKey] == nil)
    }

    /// The outcome-follow-up category is unchanged/reused verbatim (docs/31 "I."): even if a
    /// rule-sourced outcome-follow-up candidate somehow carried a `snoozeMinutes` value, its own
    /// four-action category always wins — never two categories fighting over one request.
    @Test func anOutcomeFollowUpCandidateKeepsItsOwnCategoryEvenWithASnoozeDuration() {
        let request = NotificationExecutor.makeRequest(for: ruleCandidate(identifier: "outcome", snoozeMinutes: 20, explanation: "Outcome follow-up"), globalPreferences: .conservativeDefault)
        #expect(request.content.categoryIdentifier == NotificationActionIdentifiers.outcomeFollowUpCategory)
    }
}
