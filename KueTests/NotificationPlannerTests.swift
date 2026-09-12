//
//  NotificationPlannerTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Planning": global defaults, event
//  overrides, task rules, disabled rules, quiet hours, permission states, per-device delivery,
//  capacity limits, stable ordering/identifiers, duplicate elimination, terminal events, Needs
//  Review, completed tasks, missing relationships.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct NotificationPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(
        title: String = "Board Review",
        eventType: EventType = .generic,
        startDate: Date,
        estimatedDurationMinutes: Int = 60,
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false,
        status: EventStatus = .upcoming
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: estimatedDurationMinutes,
            timeZoneIdentifier: "UTC", source: .manual, status: status,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, isSkipped: isSkipped
        )
    }

    private func plan(events: [KueEvent], preferences: NotificationGlobalPreferences = .conservativeDefault, authorized: Bool = true, capacity: Int = 64) -> NotificationSchedulePlan {
        NotificationPlanner.plan(NotificationPlanner.Input(
            events: events, globalPreferences: preferences, intensity: .standard,
            authorizationGranted: authorized, now: now, capacity: capacity
        ))
    }

    // MARK: - Global defaults / event overrides

    @Test func aRuleFreeEventStillGetsTheGlobalDefaultEventStartAndOutcomeFollowUp() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let result = plan(events: [event])
        #expect(result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
        #expect(result.scheduledCandidates.contains { $0.identifier == "\(event.id)-outcome-follow-up" })
    }

    @Test func anEventLevelEventStartRuleSupersedesTheDefaultEventStartAndPreEventCandidates() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-pre-event" })
        #expect(result.excludedCandidates.contains { $0.identifier == "\(event.id)-event-start" && $0.reason == .duplicate })
        let ruleCandidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(ruleCandidate != nil)
        #expect(ruleCandidate?.effectiveDeliveryDate == now.addingTimeInterval(3600 - 600))
    }

    @Test func aDisabledEventLevelRuleSuppressesTheDefaultWithoutSchedulingAnything() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, isEnabled: false)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(!result.scheduledCandidates.contains { $0.identifier == "\(event.id)-event-start" })
        #expect(!result.scheduledCandidates.contains { $0.sourceRuleID == rule.id })
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .ruleDisabled })
    }

    // MARK: - Task rules

    @Test func aTaskLevelRuleSupersedesTheDefaultTaskDueCandidate() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Prep slides", dueDate: now.addingTimeInterval(3600), offsetLabel: "soon")
        event.tasks = [task]
        let rule = NotificationRule(task: task, anchor: .taskDue, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        task.notificationRules = [rule]

        let result = plan(events: [event])
        let defaultTaskIdentifier = "\(event.id)-task-\(task.id.uuidString)"
        #expect(!result.scheduledCandidates.contains { $0.identifier == defaultTaskIdentifier })
        #expect(result.scheduledCandidates.contains { $0.sourceRuleID == rule.id })
    }

    @Test func aCompletedTasksRuleIsExcludedAsTaskCompleted() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let task = KueTask(event: event, title: "Prep slides", dueDate: now.addingTimeInterval(3600), isCompleted: true, offsetLabel: "soon")
        event.tasks = [task]
        let rule = NotificationRule(task: task, anchor: .taskDue, offsetDirection: .at, offsetQuantity: 0)
        task.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .taskCompleted })
    }

    // MARK: - Absolute rules

    @Test func anAbsoluteRuleInThePastIsExcludedAsPassed() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let rule = NotificationRule(event: event, anchor: .absolute, absoluteDate: now.addingTimeInterval(-3600))
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .passed })
    }

    @Test func anAbsoluteRuleInTheFutureIsScheduled() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let fireDate = now.addingTimeInterval(3600)
        let rule = NotificationRule(event: event, anchor: .absolute, absoluteDate: fireDate)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate?.effectiveDeliveryDate == fireDate)
    }

    @Test func anInvalidStoredRuleIsExcludedAsInvalidRuleRatherThanCrashing() {
        // Simulates a corrupted/foreign row: `.at` direction with a nonzero offset, which the
        // editor itself could never produce but a restored/tampered backup theoretically could.
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .at, offsetQuantity: 5, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .invalidRule })
    }

    // MARK: - Terminal events / Needs Review

    // Kue 3.0 Phase 7 correction — docs/35: `.eventTerminal` was one blended reason for four
    // distinct states; each is now reported honestly as its own case.
    @Test(arguments: [
        (\KueEvent.isCancelled, NotificationExclusionReason.eventCancelled),
        (\KueEvent.isSkipped, NotificationExclusionReason.eventSkipped),
        (\KueEvent.isManuallyCompleted, NotificationExclusionReason.eventCompleted),
    ] as [(WritableKeyPath<KueEvent, Bool>, NotificationExclusionReason)])
    func aTerminalEventsRuleIsExcludedWithItsOwnSpecificReason(flagAndReason: (flag: WritableKeyPath<KueEvent, Bool>, reason: NotificationExclusionReason)) {
        var event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event[keyPath: flagAndReason.flag] = true
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == flagAndReason.reason })
    }

    @Test func anArchivedEventsRuleIsExcludedAsEventArchived() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.status = .archived
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .eventArchived })
    }

    @Test func needsReviewEventDoesNotMisclassifyARuleCandidateAsTerminal() {
        // "Needs Review" (`.awaitingOutcome` — the event's already past its own
        // `effectiveEndDate` with no explicit outcome) is not terminal (docs/25 "G."): only
        // `isCancelled`/`isSkipped`/`isManuallyCompleted`/`.archived` count as terminal for the
        // rule pipeline. A future-dated absolute rule on such an event must still schedule.
        let event = makeEvent(startDate: now.addingTimeInterval(-7200), estimatedDurationMinutes: 60)
        let fireDate = now.addingTimeInterval(3600)
        let rule = NotificationRule(event: event, anchor: .absolute, absoluteDate: fireDate)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        #expect(result.scheduledCandidates.contains { $0.sourceRuleID == rule.id })
        #expect(!result.excludedCandidates.contains { $0.sourceRuleID == rule.id })
    }

    // MARK: - Global gates

    @Test func masterDisabledExcludesTheDefaultLayerWithATypedReason() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.masterEnabled = false
        let event = makeEvent(startDate: now.addingTimeInterval(3600))

        let result = plan(events: [event], preferences: preferences)
        #expect(result.scheduledCandidates.isEmpty)
        #expect(result.excludedCandidates.contains { $0.identifier == "\(event.id)-event-start" && $0.reason == .masterDisabled })
    }

    @Test func masterDisabledExcludesARuleLevelCandidateWithATypedReason() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.masterEnabled = false
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event], preferences: preferences)
        #expect(result.scheduledCandidates.isEmpty)
        #expect(result.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .masterDisabled })
    }

    @Test func disabledOnThisDeviceExcludesEveryCandidate() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.deliverOnThisDevice = false
        let event = makeEvent(startDate: now.addingTimeInterval(3600))

        let result = plan(events: [event], preferences: preferences)
        #expect(result.scheduledCandidates.isEmpty)
        #expect(result.excludedCandidates.contains { $0.reason == .disabledOnThisDevice })
    }

    @Test func permissionDeniedExcludesEveryCandidate() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let result = plan(events: [event], authorized: false)
        #expect(result.scheduledCandidates.isEmpty)
        #expect(result.excludedCandidates.contains { $0.reason == .permissionDenied })
    }

    // MARK: - Quiet hours

    @Test func aQuietHoursSuppressedRuleIsMovedNotDroppedByDefault() {
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.quietHours = NotificationQuietHours(
            isEnabled: true, startMinute: 0, endMinute: 24 * 60 - 1, // effectively "always quiet" for this test
            enabledWeekdays: Set(1...7), allowEventStartThrough: false, allowTimeSensitiveThrough: false
        )
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let result = plan(events: [event], preferences: preferences)
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate != nil)
        #expect(candidate?.quietHoursAdjustment == .movedToQuietHoursEnd)
        #expect(candidate?.effectiveDeliveryDate != candidate?.requestedDeliveryDate)
    }

    // MARK: - Capacity

    @Test func capacityLimitExcludesTheFurthestOutCandidatesWithATypedReason() {
        var events: [KueEvent] = []
        for i in 0..<10 {
            let event = makeEvent(title: "Event \(i)", startDate: now.addingTimeInterval(Double(i + 1) * 3600))
            events.append(event)
        }
        let result = plan(events: events, capacity: 3)
        #expect(result.scheduledCandidates.count == 3)
        #expect(result.excludedCandidates.contains { $0.reason == .systemCapacityLimit })
        // The nearest-dated survive; the furthest-out is excluded for capacity.
        #expect(result.scheduledCandidates.contains { $0.eventID == events[0].id })
        #expect(!result.scheduledCandidates.contains { $0.eventID == events[9].id })
    }

    // MARK: - Stable ordering / identifiers / duplicate elimination

    @Test func planningTwiceWithIdenticalInputsProducesIdenticalOrderingAndIdentifiers() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]

        let first = plan(events: [event])
        let second = plan(events: [event])
        #expect(first.scheduledCandidates.map(\.identifier) == second.scheduledCandidates.map(\.identifier))
    }

    @Test func ruleIdentifiersAreStableAcrossReplanningTheSameRule() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        event.notificationRules = [rule]
        let expectedIdentifier = "\(event.id)-rule-\(rule.id)"

        let result = plan(events: [event])
        #expect(result.scheduledCandidates.first { $0.sourceRuleID == rule.id }?.identifier == expectedIdentifier)
    }

    // MARK: - Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze"

    @Test func aRuleWithItsOwnSnoozeMinutesCarriesThatExactValueOnTheScheduledCandidate() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes, snoozeMinutes: 20)
        event.notificationRules = [rule]

        let result = plan(events: [event])
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate?.snoozeMinutes == 20)
    }

    /// "Test disabled/missing snooze configuration": a rule that never set its own
    /// `snoozeMinutes` (the rule editor's own "Use global default" option) still gets a
    /// concrete, non-nil snooze duration — falling back to
    /// `NotificationGlobalPreferences.defaultSnoozeMinutes` — never "no snooze at all."
    @Test func aRuleWithNoSnoozeMinutesFallsBackToTheGlobalDefault() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes, snoozeMinutes: nil)
        event.notificationRules = [rule]
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.defaultSnoozeMinutes = 45

        let result = plan(events: [event], preferences: preferences)
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate?.snoozeMinutes == 45)
    }

    /// Even a global-preferences blob decoded from before this completion pass
    /// (`defaultSnoozeMinutes == nil`) still resolves to a safe, fixed 10 minutes rather than
    /// leaving the candidate with no snooze duration at all.
    @Test func aMissingGlobalDefaultSnoozeFallsBackToTenMinutes() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes, snoozeMinutes: nil)
        event.notificationRules = [rule]
        var preferences = NotificationGlobalPreferences.conservativeDefault
        preferences.defaultSnoozeMinutes = nil

        let result = plan(events: [event], preferences: preferences)
        let candidate = result.scheduledCandidates.first { $0.sourceRuleID == rule.id }
        #expect(candidate?.snoozeMinutes == 10)
    }

    /// Default-layer candidates (no owning `NotificationRule`) never carry a snooze duration —
    /// the snooze action is scoped to rule-sourced candidates only.
    @Test func defaultLayerCandidatesNeverCarryASnoozeMinutesValue() {
        let event = makeEvent(startDate: now.addingTimeInterval(3600))
        let result = plan(events: [event])
        let defaultCandidate = result.scheduledCandidates.first { $0.identifier == "\(event.id)-event-start" }
        #expect(defaultCandidate?.snoozeMinutes == nil)
    }
}
