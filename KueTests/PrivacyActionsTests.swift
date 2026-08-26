//
//  PrivacyActionsTests.swift
//  KueTests
//
//  See docs/11-privacy-and-offline.md "Privacy principles" — "delete everything" is a
//  required action, not optional. Genuine V1 gap found during the Phase 10 audit; this file
//  is its test coverage.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct PrivacyActionsTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func deletesEveryEventAndItsCascadingChildren() {
        let context = makeContext()
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: .now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual)
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context)
        #expect(!event.tasks.isEmpty)

        #expect(PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader()))

        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.isEmpty == true)
        #expect((try? context.fetch(FetchDescriptor<KueTask>()))?.isEmpty == true)
        #expect((try? context.fetch(FetchDescriptor<KueSchedule>()))?.isEmpty == true)
    }

    @Test func resetsUserPreferenceToDeclaredDefaults() {
        let context = makeContext()
        let preference = UserPreferenceStore.current(context: context)
        preference.notificationIntensity = .all
        preference.aiParsingEnabled = false
        try? context.save()

        PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader())

        let reset = UserPreferenceStore.current(context: context)
        #expect(reset.notificationIntensity == .standard)
        #expect(reset.aiParsingEnabled == true)
    }

    @Test func removesEveryPendingNotificationForEveryDeletedEvent() {
        let context = makeContext()
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: .now.addingTimeInterval(10 * 86_400), estimatedDurationMinutes: 60, source: .manual)
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context)
        let expectedIdentifiers = Set(NotificationCandidateBuilder.allIdentifiers(for: event))

        let scheduler = FakeNotificationScheduler()
        PrivacyActions.deleteEverything(context: context, scheduler: scheduler, widgetReloader: FakeWidgetReloader())

        #expect(expectedIdentifiers.isSubset(of: Set(scheduler.allRemovedIdentifiers)))
    }

    @Test func invokesTheInjectableWidgetReloader() {
        let context = makeContext()
        let reloader = FakeWidgetReloader()
        PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: reloader)
        #expect(reloader.reloadedKinds == [WidgetKind.kue])
    }

    @Test func isANoOpSuccessWhenThereWasNothingToDelete() {
        let context = makeContext()
        #expect(PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader()))
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.isEmpty == true)
    }
}
