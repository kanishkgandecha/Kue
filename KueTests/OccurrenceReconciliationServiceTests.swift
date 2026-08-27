//
//  OccurrenceReconciliationServiceTests.swift
//  KueTests
//
//  Kue 2.0 Phase 3 — the SwiftData-touching half of docs/17-recurring-events.md: series
//  creation, bounded/idempotent replenishment, the This Occurrence / This and Future edit
//  split, deletion with exclusions, and deterministic task generation through the existing
//  SchedulingEngine for every materialized occurrence.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct OccurrenceReconciliationServiceTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Inserts the first occurrence of a fresh series exactly the way EventFormView.save()
    /// does, then materializes the rest of the initial horizon.
    @discardableResult
    private func makeSeries(
        context: ModelContext,
        eventType: EventType = .generic,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        rule: RecurrenceRule
    ) -> [KueEvent] {
        let first = KueEvent(
            title: "Standup",
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: eventType.defaultEstimatedDurationMinutes,
            isAllDay: isAllDay,
            timeZoneIdentifier: "UTC",
            source: .manual
        )
        context.insert(first)
        let widgetConfiguration = WidgetConfiguration(event: first, widgetType: WidgetType.defaultType(for: eventType))
        context.insert(widgetConfiguration)
        first.widgetConfiguration = widgetConfiguration
        SchedulingEngine.regenerateTasks(for: first, context: context, now: now)

        first.recurrence = rule
        first.seriesID = UUID()
        first.recurrenceAnchorDate = first.startDate

        let rest = OccurrenceReconciliationService.materializeInitialOccurrences(from: first, context: context, now: now)
        try? context.save()
        return [first] + rest
    }

    // MARK: - Series creation and stable identity (requirements: series identity, occurrence identity)

    @Test func everyMaterializedOccurrenceSharesTheSameSeriesID() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let seriesIDs = Set(occurrences.compactMap(\.seriesID))
        #expect(seriesIDs.count == 1)
        #expect(occurrences.count > 1)
    }

    @Test func everyOccurrenceHasAUniqueStableID() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        #expect(Set(occurrences.map(\.id)).count == occurrences.count)
    }

    @Test func occurrencesAreSpacedByTheRulesInterval() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .daily, interval: 2, end: .afterOccurrences(4)))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        #expect(sorted.count == 4)
        for i in 1..<sorted.count {
            #expect(sorted[i].startDate.timeIntervalSince(sorted[i - 1].startDate) == 2 * 86_400)
        }
    }

    // MARK: - Deterministic task generation through SchedulingEngine (requirement 17)

    @Test func everyMaterializedOccurrenceGetsItsOwnTasksFromSchedulingEngine() {
        let context = makeContext()
        let occurrences = makeSeries(
            context: context, eventType: .deadline, startDate: now.addingTimeInterval(20 * 86_400),
            rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(3))
        )
        for occurrence in occurrences {
            let expectedPlan = SchedulingEngine.plan(
                startDate: occurrence.startDate, timeZoneIdentifier: occurrence.timeZoneIdentifier,
                isAllDay: occurrence.isAllDay, eventType: occurrence.eventType,
                rules: occurrence.schedule?.rules ?? [], now: now
            )
            #expect(occurrence.tasks.count == expectedPlan.count)
            let actualDueDates = Set(occurrence.tasks.map(\.dueDate))
            let expectedDueDates = Set(expectedPlan.map(\.dueDate))
            #expect(actualDueDates == expectedDueDates)
        }
    }

    @Test func allDayRecurringEventsSkipTimeSensitiveRulesPerOccurrence() {
        let context = makeContext()
        let occurrences = makeSeries(
            context: context, eventType: .interview, startDate: now.addingTimeInterval(20 * 86_400),
            isAllDay: true, rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(3))
        )
        for occurrence in occurrences {
            #expect(occurrence.isAllDay)
            // Interview's template has one time-sensitive rule ("1h before") — every occurrence
            // must skip it, same as a single all-day event would (docs/03 "All-day events").
            #expect(occurrence.tasks.allSatisfy { !$0.offsetLabel.contains("hour") })
        }
    }

    @Test func recurringTripCarriesItsOriginalLengthForwardToEveryOccurrence() {
        let context = makeContext()
        let start = now.addingTimeInterval(10 * 86_400)
        let end = start.addingTimeInterval(3 * 86_400) // a 3-day trip
        let occurrences = makeSeries(
            context: context, eventType: .trip, startDate: start, endDate: end,
            rule: RecurrenceRule(frequency: .monthly, interval: 1, end: .afterOccurrences(3))
        )
        for occurrence in occurrences {
            guard let endDate = occurrence.endDate else {
                Issue.record("expected every recurring trip occurrence to have an endDate")
                continue
            }
            let lengthDays = Calendar(identifier: .gregorian).dateComponents([.day], from: occurrence.startDate, to: endDate).day
            #expect(lengthDays == 3)
        }
    }

    // MARK: - Bounded materialization + idempotent, duplicate-free replenishment (requirements
    // 5, 18)

    @Test func replenishingTwiceWithNoTimePassedCreatesNoNewOccurrences() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let countBefore = occurrences.count

        let changed = OccurrenceReconciliationService.replenishAll(context: context, now: now)
        #expect(changed == false)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(allEvents.count == countBefore)
    }

    @Test func replenishingAfterTimePassesExtendsTheHorizonWithoutDuplicates() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let originalAnchors = Set(occurrences.compactMap(\.recurrenceAnchorDate))

        let later = now.addingTimeInterval(60 * 86_400)
        let changed = OccurrenceReconciliationService.replenishAll(context: context, now: later)
        #expect(changed)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let newAnchors = Set(allEvents.compactMap(\.recurrenceAnchorDate))
        #expect(newAnchors.isSuperset(of: originalAnchors)) // nothing already materialized was lost
        #expect(newAnchors.count > originalAnchors.count) // and new future slots were added

        // Duplicate-free: no two occurrences in the series share an anchor.
        let seriesID = occurrences.first?.seriesID
        let seriesAnchors = allEvents.filter { $0.seriesID == seriesID }.compactMap(\.recurrenceAnchorDate)
        #expect(Set(seriesAnchors).count == seriesAnchors.count)
    }

    @Test func neverEndingSeriesMaterializationIsBoundedNotUnlimited() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .daily, interval: 1, end: .never))
        // Origin + up to RecurrenceEngine.maximumMaterializedOccurrences more — never "one row
        // per day forever."
        #expect(occurrences.count <= RecurrenceEngine.maximumMaterializedOccurrences + 1)
        #expect(occurrences.count > 1)
    }

    // MARK: - Explicit exceptions survive reconciliation unconditionally (requirement 5/28)

    @Test func replenishmentNeverOverwritesAnOccurrenceMarkedAsAnException() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let target = occurrences.sorted { $0.startDate < $1.startDate }[1]
        target.title = "Customized Standup"
        target.isRecurrenceException = true
        try? context.save()

        OccurrenceReconciliationService.replenishAll(context: context, now: now.addingTimeInterval(90 * 86_400))

        let targetID = target.id
        let refetched = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == targetID })))?.first
        #expect(refetched?.title == "Customized Standup")
    }

    // MARK: - This Occurrence edit (requirements 12, 13)

    @Test func thisOccurrenceEditMutatesOnlyThatRowAndMarksItAnException() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(5)))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let target = sorted[2]
        let untouchedIDs = Set(sorted.filter { $0.id != target.id }.map(\.id))
        let untouchedSnapshotTitles = sorted.filter { $0.id != target.id }.map(\.title)

        var draft = EventDraft(title: "One-off standup", eventType: target.eventType, startDate: target.startDate.addingTimeInterval(3_600))
        draft.timeZoneIdentifier = target.timeZoneIdentifier

        let outcome = OccurrenceReconciliationService.applyEdit(scope: .thisOccurrence, to: target, values: draft, context: context, now: now)

        #expect(target.title == "One-off standup")
        #expect(target.isRecurrenceException)
        #expect(target.seriesID == sorted[0].seriesID) // still belongs to the same series
        #expect(outcome.affectedOccurrences.map(\.id) == [target.id])

        let others = sorted.filter { $0.id != target.id }
        #expect(Set(others.map(\.id)) == untouchedIDs)
        #expect(others.map(\.title) == untouchedSnapshotTitles) // unrelated occurrences never mutated
    }

    // MARK: - This and Future Occurrences (requirement 14)

    @Test func thisAndFutureEditPreservesHistoryAndSplitsIntoANewSeries() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let splitPoint = sorted[2]
        let before = Array(sorted[0..<2])
        let originalSeriesID = splitPoint.seriesID
        let beforeSeriesIDs = before.map(\.seriesID)
        let beforeTitles = before.map(\.title)

        var draft = EventDraft(title: "New Team Sync", eventType: splitPoint.eventType, startDate: splitPoint.startDate)
        draft.timeZoneIdentifier = splitPoint.timeZoneIdentifier

        let outcome = OccurrenceReconciliationService.applyEdit(scope: .thisAndFuture, to: splitPoint, values: draft, context: context, now: now)

        // Historical occurrences (before the split) are completely untouched.
        #expect(before.map(\.seriesID) == beforeSeriesIDs)
        #expect(before.map(\.title) == beforeTitles)

        // The split point becomes the head of a brand-new series with the new field values.
        #expect(splitPoint.title == "New Team Sync")
        #expect(splitPoint.seriesID != originalSeriesID)
        #expect(splitPoint.isRecurrenceException == false)
        #expect(!outcome.affectedOccurrences.isEmpty)

        // Every future occurrence materialized under the new segment shares the new title and
        // the new seriesID.
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let newSegment = allEvents.filter { $0.seriesID == splitPoint.seriesID }
        #expect(newSegment.count > 1)
        #expect(newSegment.allSatisfy { $0.title == "New Team Sync" })
    }

    @Test func thisAndFuturePreservesAPriorExceptionAfterTheSplitPoint() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let splitPoint = sorted[1]
        let exceptionAfterSplit = sorted[3]
        exceptionAfterSplit.title = "Already Customized"
        exceptionAfterSplit.isRecurrenceException = true
        try? context.save()

        var draft = EventDraft(title: "New Title", eventType: splitPoint.eventType, startDate: splitPoint.startDate)
        draft.timeZoneIdentifier = splitPoint.timeZoneIdentifier
        _ = OccurrenceReconciliationService.applyEdit(scope: .thisAndFuture, to: splitPoint, values: draft, context: context, now: now)

        let exceptionID = exceptionAfterSplit.id
        let refetched = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == exceptionID })))?.first
        // The exception's own edit is preserved exactly — never clobbered by the new template —
        // but it's reparented to the new segment.
        #expect(refetched?.title == "Already Customized")
        #expect(refetched?.seriesID == splitPoint.seriesID)
    }

    @Test func thisAndFutureFromTheFirstOccurrenceIsANoOpSplitInPlace() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .afterOccurrences(4)))
        let first = occurrences.sorted { $0.startDate < $1.startDate }[0]
        let originalSeriesID = first.seriesID

        var draft = EventDraft(title: "Renamed From Start", eventType: first.eventType, startDate: first.startDate)
        draft.timeZoneIdentifier = first.timeZoneIdentifier
        _ = OccurrenceReconciliationService.applyEdit(scope: .thisAndFuture, to: first, values: draft, context: context, now: now)

        // No prior occurrence exists — nothing to split, so the seriesID is unchanged.
        #expect(first.seriesID == originalSeriesID)
        #expect(first.title == "Renamed From Start")
    }

    @Test func thisAndFutureCanChangeTheRuleItselfGoingForward() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let splitPoint = sorted[1]

        var draft = EventDraft(title: splitPoint.title, eventType: splitPoint.eventType, startDate: splitPoint.startDate)
        draft.timeZoneIdentifier = splitPoint.timeZoneIdentifier
        draft.isRecurring = true
        draft.recurrenceFrequency = .weekly
        draft.recurrenceInterval = 3 // was 1
        draft.recurrenceEndKind = .never

        _ = OccurrenceReconciliationService.applyEdit(scope: .thisAndFuture, to: splitPoint, values: draft, context: context, now: now)

        #expect(splitPoint.recurrence?.interval == 3)
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let newSegment = allEvents.filter { $0.seriesID == splitPoint.seriesID }.sorted { $0.startDate < $1.startDate }
        #expect(newSegment.count > 1)
        for i in 1..<newSegment.count {
            #expect(newSegment[i].startDate.timeIntervalSince(newSegment[i - 1].startDate) == 3 * 7 * 86_400)
        }
    }

    // MARK: - Deletion (requirement 9's "Deleting one occurrence" / requirement 16)

    @Test func deletingThisOccurrenceExcludesItsSlotFromFutureReplenishment() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let target = sorted[2]
        let targetAnchor = target.recurrenceAnchorDate
        let seriesID = target.seriesID

        OccurrenceReconciliationService.deleteOccurrence(target, scope: .thisOccurrence, context: context)

        var allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(allEvents.contains { $0.id == target.id } == false)

        // Replenishing well past the deleted slot must not recreate it.
        OccurrenceReconciliationService.replenishAll(context: context, now: now.addingTimeInterval(90 * 86_400))
        allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let seriesAnchors = allEvents.filter { $0.seriesID == seriesID }.compactMap(\.recurrenceAnchorDate)
        #expect(!seriesAnchors.contains(where: { $0 == targetAnchor }))
    }

    @Test func deletingThisAndFutureRemovesEveryFutureOccurrenceAndStopsTheSeries() {
        let context = makeContext()
        let occurrences = makeSeries(context: context, startDate: now.addingTimeInterval(86_400), rule: RecurrenceRule(frequency: .weekly, interval: 1, end: .never))
        let sorted = occurrences.sorted { $0.startDate < $1.startDate }
        let splitPoint = sorted[1]
        let seriesID = splitPoint.seriesID
        let historicalID = sorted[0].id

        OccurrenceReconciliationService.deleteOccurrence(splitPoint, scope: .thisAndFuture, context: context)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        // The one occurrence before the split point survives untouched.
        #expect(allEvents.contains { $0.id == historicalID })
        // Nothing at or after the split point remains.
        #expect(allEvents.contains { $0.id == splitPoint.id } == false)
        for occurrence in sorted[2...] {
            #expect(allEvents.contains { $0.id == occurrence.id } == false)
        }

        // Replenishing afterward must not resurrect the series.
        OccurrenceReconciliationService.replenishAll(context: context, now: now.addingTimeInterval(90 * 86_400))
        let afterReplenish = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(afterReplenish.filter { $0.seriesID == seriesID }.count == 1) // only the historical one
    }

    @Test func deletingANonRecurringEventStillUsesThePlainDeletePath() {
        let context = makeContext()
        let event = KueEvent(title: "One-off", eventType: .generic, startDate: now.addingTimeInterval(86_400), estimatedDurationMinutes: 0, source: .manual)
        context.insert(event)
        try? context.save()

        OccurrenceReconciliationService.deleteOccurrence(event, scope: .thisOccurrence, context: context)
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.isEmpty == true)
        #expect((try? context.fetch(FetchDescriptor<RecurrenceExclusion>()))?.isEmpty == true)
    }
}
