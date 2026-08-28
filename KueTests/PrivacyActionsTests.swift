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
        // Kue 2.0 Phase 10 — docs/24 "I.": both widget kinds reload now, matching every other
        // mutation path (`EventActions.reloadWidget`/`WidgetIntentActions.reloadAllWidgetKinds`).
        #expect(reloader.reloadedKinds == [WidgetKind.kue, WidgetKind.dedicatedCountdown])
    }

    /// Kue 2.0 Phase 10 — docs/24 "I.": nothing left to focus once every event is gone.
    @Test func endsAnyFocusedLiveActivity() async throws {
        let context = makeContext()
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: .now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual)
        context.insert(event)
        try? context.save()
        let manager = FakeLiveActivityManager()
        _ = await manager.start(for: event, now: .now)
        #expect(manager.runningEventID == event.id)

        #expect(PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), liveActivityManager: manager))
        try await Task.sleep(nanoseconds: 50_000_000) // fire-and-forget Task
        #expect(manager.runningEventID == nil)
    }

    @Test func removesEverySpotlightEntry() async throws {
        let context = makeContext()
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: .now.addingTimeInterval(86_400), estimatedDurationMinutes: 60, source: .manual)
        context.insert(event)
        try? context.save()
        let indexer = FakeSpotlightIndexer()
        await indexer.index([SpotlightEventPayloadBuilder.payload(for: event)])

        #expect(PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader(), spotlightIndexer: indexer))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(indexer.indexedPayloads.isEmpty)
    }

    @Test func isANoOpSuccessWhenThereWasNothingToDelete() {
        let context = makeContext()
        #expect(PrivacyActions.deleteEverything(context: context, scheduler: FakeNotificationScheduler(), widgetReloader: FakeWidgetReloader()))
        #expect((try? context.fetch(FetchDescriptor<KueEvent>()))?.isEmpty == true)
    }
}
