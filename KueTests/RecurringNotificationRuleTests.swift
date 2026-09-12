//
//  RecurringNotificationRuleTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Recurring events": series-created
//  occurrences inherit intended rules, this-occurrence overrides remain isolated, deleted
//  occurrences lose pending requests, skipped occurrences don't notify, and reconciliation
//  doesn't duplicate requests when the horizon replenishes.
//
//  Shares `OccurrenceReconciliationServiceTests`' own `.eventActionsSyncOutboxSerialized` trait
//  — every function this file exercises (`materializeInitialOccurrences`/`deleteOccurrence`)
//  hits the same real, process-global `SystemCloudSyncStateStore.shared` that file's own header
//  documents the race against; see that header for the full explanation.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite(.serialized, .eventActionsSyncOutboxSerialized)
@MainActor
struct RecurringNotificationRuleTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @discardableResult
    private func makeSeries(context: ModelContext, startDate: Date, rule: RecurrenceRule) -> [KueEvent] {
        let first = KueEvent(
            title: "Standup", eventType: .generic, startDate: startDate,
            estimatedDurationMinutes: 30, timeZoneIdentifier: "UTC", source: .manual
        )
        context.insert(first)
        first.recurrence = rule
        first.seriesID = UUID()
        first.recurrenceAnchorDate = first.startDate
        let rest = OccurrenceReconciliationService.materializeInitialOccurrences(from: first, context: context, now: now)
        try? context.save()
        return [first] + rest
    }

    // MARK: - Inheritance

    @Test func seriesCreatedOccurrencesInheritTheOriginsEventLevelRule() {
        let context = makeContext()
        let first = KueEvent(
            title: "Standup", eventType: .generic, startDate: now.addingTimeInterval(86_400),
            estimatedDurationMinutes: 30, timeZoneIdentifier: "UTC", source: .manual
        )
        context.insert(first)
        first.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
        first.seriesID = UUID()
        first.recurrenceAnchorDate = first.startDate
        let rule = NotificationRule(event: first, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)
        first.notificationRules = [rule]

        let occurrences = OccurrenceReconciliationService.materializeInitialOccurrences(from: first, context: context, now: now)
        try? context.save()

        #expect(!occurrences.isEmpty)
        for occurrence in occurrences {
            #expect(occurrence.notificationRules.count == 1)
            let copied = try? #require(occurrence.notificationRules.first)
            #expect(copied?.anchor == .eventStart)
            #expect(copied?.offsetQuantity == 15)
            // A fresh, independent copy — never the same row re-parented.
            #expect(copied?.id != rule.id)
        }
    }

    @Test func anAbsoluteRuleIsNeverCopiedToAnotherOccurrence() {
        // An absolute rule is a one-time, occurrence-specific reminder — docs/31 "Recurring
        // events" implies isolation for anything that can't meaningfully generalize across
        // occurrences with different dates.
        let context = makeContext()
        let first = KueEvent(
            title: "Standup", eventType: .generic, startDate: now.addingTimeInterval(86_400),
            estimatedDurationMinutes: 30, timeZoneIdentifier: "UTC", source: .manual
        )
        context.insert(first)
        first.recurrence = RecurrenceRule(frequency: .weekly, interval: 1, end: .never)
        first.seriesID = UUID()
        first.recurrenceAnchorDate = first.startDate
        let absoluteRule = NotificationRule(event: first, anchor: .absolute, absoluteDate: now.addingTimeInterval(3600))
        first.notificationRules = [absoluteRule]

        let occurrences = OccurrenceReconciliationService.materializeInitialOccurrences(from: first, context: context, now: now)
        try? context.save()

        #expect(!occurrences.isEmpty)
        for occurrence in occurrences {
            #expect(occurrence.notificationRules.isEmpty)
        }
    }

    // MARK: - This-occurrence isolation

    @Test func aThisOccurrenceOnlyRuleNeverAppearsOnASiblingOccurrence() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        #expect(occurrences.count > 1)

        let firstOccurrence = occurrences[0]
        let secondOccurrence = occurrences[1]
        let customRule = NotificationRule(event: secondOccurrence, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 5, offsetUnit: .minutes)
        secondOccurrence.notificationRules = [customRule]
        try? context.save()

        #expect(firstOccurrence.notificationRules.isEmpty)
        #expect(secondOccurrence.notificationRules.count == 1)
    }

    // MARK: - Deletion / exclusion

    @Test func deletingAnOccurrenceRemovesItsRulesPendingRequestToo() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let target = occurrences[0]
        let rule = NotificationRule(event: target, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        target.notificationRules = [rule]
        try? context.save()
        let ruleIdentifier = "\(target.id)-rule-\(rule.id)"

        let scheduler = FakeNotificationScheduler()
        OccurrenceReconciliationService.deleteOccurrence(target, scope: .thisOccurrence, context: context, scheduler: scheduler)

        #expect(scheduler.allRemovedIdentifiers.contains(ruleIdentifier))
    }

    @Test func skippedOccurrencesProduceNoDefaultLayerCandidatesAndTheirOwnRulesAreExcludedAsTerminal() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let target = occurrences[0]
        let rule = NotificationRule(event: target, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)
        target.notificationRules = [rule]
        target.isSkipped = true
        try? context.save()

        let plan = NotificationPlanner.plan(NotificationPlanner.Input(
            events: [target], globalPreferences: .conservativeDefault, intensity: .standard,
            authorizationGranted: true, now: now, capacity: 64
        ))
        #expect(plan.scheduledCandidates.isEmpty)
        #expect(plan.excludedCandidates.contains { $0.sourceRuleID == rule.id && $0.reason == .eventSkipped })
    }

    // MARK: - Replenishment doesn't duplicate

    @Test func replenishingTwiceNeverDuplicatesAnInheritedRuleOnNewlyMaterializedOccurrences() {
        let context = makeContext()
        let first = KueEvent(
            title: "Standup", eventType: .generic, startDate: now.addingTimeInterval(86_400),
            estimatedDurationMinutes: 30, timeZoneIdentifier: "UTC", source: .manual
        )
        context.insert(first)
        first.recurrence = RecurrenceRule(frequency: .daily, interval: 1, end: .never)
        first.seriesID = UUID()
        first.recurrenceAnchorDate = first.startDate
        first.notificationRules = [NotificationRule(event: first, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)]
        OccurrenceReconciliationService.materializeInitialOccurrences(from: first, context: context, now: now)
        try? context.save()

        OccurrenceReconciliationService.replenishAll(context: context, now: now)
        OccurrenceReconciliationService.replenishAll(context: context, now: now)
        try? context.save()

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        for event in allEvents where event.seriesID == first.seriesID {
            // Every occurrence, however it was created, carries at most the one rule its own
            // template intended — never accumulated duplicates across repeated replenishment.
            #expect(event.notificationRules.count <= 1)
        }
    }
}
