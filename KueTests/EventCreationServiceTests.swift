//
//  EventCreationServiceTests.swift
//  KueTests
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "A./I." — the shared create path both
//  `EventFormView.save()` and every creating App Intent (`CreateEventIntent`/
//  `QuickAddEventIntent`/`CreateEventFromTemplateIntent`) route through. Covers the write
//  itself, the shared post-write reconciliation (notifications/Live Activity/Spotlight), and
//  that recurrence still materializes correctly from this shared path.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct EventCreationServiceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func createPersistsAllCoreFields() {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Panel Interview"
        draft.startDate = now.addingTimeInterval(3_600)

        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        #expect(event.title == "Panel Interview")
        #expect(event.eventType == .interview)
        #expect(event.source == .shortcuts)
        #expect(event.widgetConfiguration != nil)
    }

    @Test func createRegeneratesTheDefaultPreparationSchedule() {
        let context = makeContext()
        var draft = EventDraft(eventType: .exam)
        draft.title = "Final Exam"
        draft.startDate = now.addingTimeInterval(30 * 86_400)

        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)
        #expect(!event.tasks.isEmpty)
    }

    @Test func createMaterializesARecurringSeriesWhenTheDraftRequestsOne() {
        let context = makeContext()
        var draft = EventDraft(eventType: .generic)
        draft.title = "Weekly Sync"
        draft.startDate = now.addingTimeInterval(86_400)
        draft.isRecurring = true
        draft.recurrenceFrequency = .weekly
        draft.recurrenceInterval = 1
        draft.recurrenceEndKind = .afterCount
        draft.recurrenceOccurrenceCount = 3

        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)
        #expect(event.seriesID != nil)

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let seriesMembers = allEvents.filter { $0.seriesID == event.seriesID }
        #expect(seriesMembers.count > 1)
    }

    @Test func reconcileAfterWriteIndexesTheNewEventInSpotlight() async {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Panel Interview"
        draft.startDate = now.addingTimeInterval(3_600)
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        let spotlightIndexer = FakeSpotlightIndexer()
        let liveActivityManager = FakeLiveActivityManager()
        await EventCreationService.reconcileAfterWrite(
            event, context: context, now: now,
            liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer
        )

        #expect(spotlightIndexer.indexedPayloads[event.id]?.title == "Panel Interview")
    }

    @Test func reconcileAfterWriteIsANoOpForLiveActivityWhenNothingIsFocused() async {
        let context = makeContext()
        var draft = EventDraft(eventType: .interview)
        draft.title = "Unrelated Event"
        draft.startDate = now.addingTimeInterval(3_600)
        let event = EventCreationService.create(from: draft, source: .shortcuts, context: context, now: now)

        let liveActivityManager = FakeLiveActivityManager()
        await EventCreationService.reconcileAfterWrite(
            event, context: context, now: now,
            liveActivityManager: liveActivityManager, spotlightIndexer: FakeSpotlightIndexer()
        )
        // Nothing was ever focused — creating an unrelated event must never start/select one.
        #expect(liveActivityManager.runningEventID == nil)
    }

    // MARK: - Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults"

    @Test func creatingAnEventWithNoBuiltInTemplateRowGetsNoNotificationRules() {
        let context = makeContext()
        var draft = EventDraft(eventType: .exam)
        draft.title = "Untemplated Exam"
        draft.startDate = now.addingTimeInterval(3_600)

        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)
        // Zero rows means inherit from global defaults, not "disabled" — docs/31 "Migration".
        #expect(event.notificationRules.isEmpty)
    }

    @Test func creatingAnEventCopiesTheEventTypesTemplateNotificationDefaults() {
        let context = makeContext()
        let template = TemplateStore.fetchOrCreateBuiltIn(for: .exam, context: context)
        template.notificationRuleDefaults = [
            NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 45, offsetUnit: .minutes, customTitle: "Exam soon"),
            NotificationRuleDefault(anchor: .outcomeFollowUp, offsetDirection: .after, offsetQuantity: 2, offsetUnit: .hours, snoozeMinutes: 10),
        ]
        try? context.save()

        var draft = EventDraft(eventType: .exam)
        draft.title = "Final Exam"
        draft.startDate = now.addingTimeInterval(30 * 86_400)
        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)

        #expect(event.notificationRules.count == 2)
        let startRule = event.notificationRules.first { $0.anchor == .eventStart }
        #expect(startRule?.offsetQuantity == 45)
        #expect(startRule?.customTitle == "Exam soon")
        #expect(startRule?.event === event)
        let followUpRule = event.notificationRules.first { $0.anchor == .outcomeFollowUp }
        #expect(followUpRule?.snoozeMinutes == 10)
    }

    @Test func templateNotificationDefaultsOnlyApplyToTheirOwnEventType() {
        let context = makeContext()
        let examTemplate = TemplateStore.fetchOrCreateBuiltIn(for: .exam, context: context)
        examTemplate.notificationRuleDefaults = [NotificationRuleDefault(anchor: .eventStart, offsetQuantity: 45, offsetUnit: .minutes)]
        try? context.save()

        var tripDraft = EventDraft(eventType: .trip)
        tripDraft.title = "Tokyo Trip"
        tripDraft.startDate = now.addingTimeInterval(30 * 86_400)
        let tripEvent = EventCreationService.create(from: tripDraft, source: .manual, context: context, now: now)

        #expect(tripEvent.notificationRules.isEmpty)
    }

    /// docs/31 "Template notification defaults": "do not silently mutate already-created
    /// events unless that is explicitly the architecture" — a snapshot copy, never a live link.
    @Test func editingATemplateAfterAnEventWasCreatedNeverMutatesThatEvent() {
        let context = makeContext()
        let template = TemplateStore.fetchOrCreateBuiltIn(for: .interview, context: context)
        template.notificationRuleDefaults = [NotificationRuleDefault(anchor: .eventStart, offsetQuantity: 30, offsetUnit: .minutes)]
        try? context.save()

        var draft = EventDraft(eventType: .interview)
        draft.title = "Panel Interview"
        draft.startDate = now.addingTimeInterval(3_600)
        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)
        #expect(event.notificationRules.count == 1)
        let copiedRuleID = event.notificationRules[0].id

        // Edit the template after the fact — add, change, and remove defaults entirely.
        template.notificationRuleDefaults = [NotificationRuleDefault(anchor: .eventStart, offsetQuantity: 999, offsetUnit: .minutes)]
        try? context.save()

        #expect(event.notificationRules.count == 1)
        #expect(event.notificationRules[0].id == copiedRuleID)
        #expect(event.notificationRules[0].offsetQuantity == 30) // unchanged, not 999

        template.notificationRuleDefaults = []
        try? context.save()
        #expect(event.notificationRules.count == 1) // still there — never re-derived from the template
    }

    /// `TemplateNotificationAnchor` structurally excludes `.absolute` — see
    /// `NotificationRuleDefault.swift`'s own header — so this proves the copy path can never
    /// produce a rule with a stale one-time absolute timestamp, for every anchor it does support.
    @Test func copiedRulesNeverCarryAnAbsoluteDate() {
        let context = makeContext()
        let template = TemplateStore.fetchOrCreateBuiltIn(for: .deadline, context: context)
        template.notificationRuleDefaults = TemplateNotificationAnchor.allCases.map {
            NotificationRuleDefault(anchor: $0, offsetDirection: .before, offsetQuantity: 1, offsetUnit: .hours)
        }
        try? context.save()

        var draft = EventDraft(eventType: .deadline)
        draft.title = "Tax Filing"
        draft.startDate = now.addingTimeInterval(20 * 86_400)
        let event = EventCreationService.create(from: draft, source: .manual, context: context, now: now)

        #expect(event.notificationRules.count == TemplateNotificationAnchor.allCases.count)
        #expect(event.notificationRules.allSatisfy { $0.absoluteDate == nil })
    }
}
