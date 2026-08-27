//
//  EventDuplicationServiceTests.swift
//  KueTests
//
//  Kue 2.0 Phase 2, requirement 13 — duplication of every event type, fresh identifiers,
//  independent relationships, regenerated tasks, notification scheduling, widget reload
//  invocation. Same fake-injection pattern as EventActionsNotificationTests/
//  WidgetIntentActionsTests: never a real UNUserNotificationCenter or WidgetCenter call.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct EventDuplicationServiceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func insertEvent(
        in context: ModelContext,
        title: String = "Original",
        eventType: EventType = .interview,
        startDate: Date? = nil,
        isCancelled: Bool = false,
        isManuallyCompleted: Bool = false,
        status: EventStatus = .upcoming
    ) -> KueEvent {
        let event = KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate ?? now.addingTimeInterval(20 * 86_400),
            endDate: eventType == .trip ? (startDate ?? now.addingTimeInterval(20 * 86_400)).addingTimeInterval(3 * 86_400) : nil,
            estimatedDurationMinutes: eventType.defaultEstimatedDurationMinutes,
            timeZoneIdentifier: "UTC",
            location: "HQ",
            notes: "Some notes",
            source: .naturalLanguage,
            priority: .high,
            status: status,
            isCancelled: isCancelled,
            isManuallyCompleted: isManuallyCompleted
        )
        context.insert(event)
        let widgetConfiguration = WidgetConfiguration(event: event, widgetType: .checklist, showLocation: false, isEnabled: false)
        context.insert(widgetConfiguration)
        event.widgetConfiguration = widgetConfiguration
        SchedulingEngine.regenerateTasks(for: event, context: context, now: now)
        return event
    }

    // MARK: - Every event type (requirement 13)

    @Test(arguments: EventType.allCases)
    func duplicatesEveryEventType(eventType: EventType) async throws {
        let context = makeContext()
        let source = insertEvent(in: context, eventType: eventType)
        let scheduler = FakeNotificationScheduler()
        let widgetReloader = FakeWidgetReloader()

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: scheduler, widgetReloader: widgetReloader, now: now)

        #expect(outcome.newEvent.eventType == eventType)
        #expect(outcome.newEvent.title == source.title)
        #expect(outcome.newEvent.startDate == source.startDate)
        #expect(outcome.newEvent.endDate == source.endDate)
        #expect(outcome.newEvent.location == source.location)
        #expect(outcome.newEvent.notes == source.notes)
        #expect(outcome.newEvent.priority == source.priority)
    }

    // MARK: - Fresh identifiers

    @Test func duplicateGetsFreshEventScheduleWidgetConfigurationAndTaskIdentifiers() async throws {
        let context = makeContext()
        let source = insertEvent(in: context)
        let sourceTaskIDs = Set(source.tasks.map(\.id))
        let sourceScheduleID = source.schedule?.id
        let sourceWidgetConfigurationID = source.widgetConfiguration?.id

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        #expect(duplicate.id != source.id)
        #expect(duplicate.schedule?.id != nil)
        #expect(duplicate.schedule?.id != sourceScheduleID)
        #expect(duplicate.widgetConfiguration?.id != nil)
        #expect(duplicate.widgetConfiguration?.id != sourceWidgetConfigurationID)
        #expect(!duplicate.tasks.isEmpty)
        #expect(Set(duplicate.tasks.map(\.id)).isDisjoint(with: sourceTaskIDs))
    }

    // MARK: - Independent relationships

    @Test func mutatingTheDuplicateDoesNotAffectTheSource() async throws {
        let context = makeContext()
        let source = insertEvent(in: context)
        let sourceTaskCount = source.tasks.count

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        duplicate.tasks.first?.isCompleted = true
        duplicate.title = "Renamed Duplicate"
        try context.save()

        #expect(source.title == "Original")
        #expect(source.tasks.count == sourceTaskCount)
        #expect(source.tasks.allSatisfy { !$0.isCompleted })
    }

    @Test func deletingTheDuplicateLeavesTheSourceAndItsChildrenIntact() async throws {
        let context = makeContext()
        let source = insertEvent(in: context)
        let sourceTaskCount = source.tasks.count

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        EventActions.delete(outcome.newEvent, context: context)

        let remaining = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == source.id)
        #expect(remaining.first?.tasks.count == sourceTaskCount)
        #expect(remaining.first?.schedule != nil)
        #expect(remaining.first?.widgetConfiguration != nil)
    }

    // MARK: - Regenerated tasks (not copied, not carrying completion state)

    @Test func regeneratedTasksMatchSchedulingEngineOutputAndAreNeverCompleted() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, eventType: .interview)
        // Complete one of the source's tasks — requirement: duplication must not copy
        // task-completion state.
        source.tasks.first?.isCompleted = true
        try context.save()

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        let expectedPlan = SchedulingEngine.plan(
            startDate: duplicate.startDate,
            timeZoneIdentifier: duplicate.timeZoneIdentifier,
            isAllDay: duplicate.isAllDay,
            eventType: duplicate.eventType,
            rules: duplicate.schedule?.rules ?? [],
            now: now
        )
        #expect(duplicate.tasks.count == expectedPlan.count)
        #expect(duplicate.tasks.allSatisfy { !$0.isCompleted })
        #expect(Set(duplicate.tasks.map(\.title)) == Set(expectedPlan.map(\.title)))
    }

    @Test func customScheduleRulesAreCopiedOntoTheDuplicate() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, eventType: .generic)
        let customRules = [ScheduleRule(offset: DateComponents(day: 5), taskTitle: "Custom Prep", isTimeSensitive: false)]
        source.schedule?.rules = customRules
        source.schedule?.isCustom = true
        try context.save()

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        #expect(duplicate.schedule?.isCustom == true)
        #expect(duplicate.schedule?.rules == customRules)
        #expect(duplicate.tasks.contains { $0.title == "Custom Prep" })
    }

    // MARK: - Never carries archived/cancelled/manually-completed state

    @Test func duplicatingACancelledEventProducesAFreshUpcomingCopy() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, isCancelled: true, status: .cancelled)

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        #expect(duplicate.isCancelled == false)
        #expect(duplicate.cancelledAt == nil)
        #expect(duplicate.status != .cancelled)
        #expect(duplicate.status != .archived)
    }

    @Test func duplicatingAManuallyCompletedEventProducesAFreshCopy() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, isManuallyCompleted: true, status: .completed)

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        #expect(duplicate.isManuallyCompleted == false)
        #expect(duplicate.manuallyCompletedAt == nil)
    }

    @Test func duplicatingAnArchivedEventProducesAFreshNonArchivedCopy() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, status: .archived)

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)
        let duplicate = outcome.newEvent

        #expect(duplicate.status != .archived)
    }

    // MARK: - Duplicate detection (requirement 10: "run duplicate detection")

    @Test func duplicatingANonArchivedEventDetectsTheSourceAsTheDuplicate() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, title: "Team Sync")

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        #expect(outcome.detectedDuplicate?.id == source.id)
    }

    @Test func duplicatingAnArchivedEventDetectsNoDuplicate() async throws {
        let context = makeContext()
        let source = insertEvent(in: context, title: "Old Archived Event", status: .archived)

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), now: now)

        #expect(outcome.detectedDuplicate == nil)
    }

    // MARK: - Notification scheduling + widget reload invocation

    @Test func duplicationReschedulesNotificationsForTheNewEvent() async throws {
        let context = makeContext()
        let source = insertEvent(in: context)
        let scheduler = FakeNotificationScheduler()

        let outcome = await EventDuplicationService.duplicate(source, context: context, scheduler: scheduler, widgetReloader: FakeWidgetReloader(), now: now)

        let duplicateIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: outcome.newEvent))
        #expect(!scheduler.addedIdentifiers.isEmpty)
        #expect(!Set(scheduler.addedIdentifiers).isDisjoint(with: duplicateIdentifiers))
    }

    @Test func duplicationInvokesWidgetTimelineReload() async throws {
        let context = makeContext()
        let source = insertEvent(in: context)
        let widgetReloader = FakeWidgetReloader()

        _ = await EventDuplicationService.duplicate(source, context: context, scheduler: FakeNotificationScheduler(), widgetReloader: widgetReloader, now: now)

        #expect(widgetReloader.reloadedKinds.contains(WidgetKind.kue))
    }
}
