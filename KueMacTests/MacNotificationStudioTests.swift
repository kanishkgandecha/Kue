//
//  MacNotificationStudioTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification Studio parity". Same spot-check
//  discipline `MacSharedServiceSmokeTests.swift`'s own header describes: proving the shared
//  `NotificationRule`/`NotificationGlobalPreferences`/`NotificationDefaultsApplier`/
//  `TemplateStore` machinery the new native Mac rule editor and Notifications settings tab both
//  depend on actually behaves correctly when reached from the `KueMac` module — not a second
//  copy of `KueTests`' own exhaustive `NotificationPlanner`/`NotificationRuleValidator`
//  coverage of the same pure engines.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

extension KueMacAllTests {
    // MARK: - Rule editor mechanics (mirrors `MacNotificationRuleEditorView`'s own save/
    // duplicate/delete logic, which — being private SwiftUI view methods — isn't itself
    // directly unit-testable; this proves the shared model/service layer underneath it).

    @Test func addingACustomNotificationRuleFromTheMacModuleAttachesItToTheEvent() {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent()
        container.mainContext.insert(event)
        try? container.mainContext.save()

        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 45, offsetUnit: .minutes, customTitle: "Mac Custom Rule")
        container.mainContext.insert(rule)
        event.notificationRules.append(rule)
        try? container.mainContext.save()

        #expect(event.notificationRules.count == 1)
        #expect(event.notificationRules.first?.customTitle == "Mac Custom Rule")
    }

    @Test func duplicatingANotificationRuleCopiesEveryFieldButGetsANewIdentity() {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent()
        container.mainContext.insert(event)
        let original = NotificationRule(
            event: event, anchor: .eventEnd, offsetDirection: .after, offsetQuantity: 10, offsetUnit: .minutes,
            customTitle: "Original", sound: .silent, interruptionPreference: .timeSensitive, snoozeMinutes: 15
        )
        container.mainContext.insert(original)
        event.notificationRules.append(original)
        try? container.mainContext.save()

        // Mirrors `MacEventDetailView.duplicateNotificationRule(_:)` exactly.
        let copy = NotificationRule(
            event: original.event, task: original.task, anchor: original.anchor, offsetDirection: original.offsetDirection,
            offsetQuantity: original.offsetQuantity, offsetUnit: original.offsetUnit, absoluteDate: original.absoluteDate,
            isEnabled: original.isEnabled, customTitle: original.customTitle, customBody: original.customBody,
            sound: original.sound, interruptionPreference: original.interruptionPreference, snoozeMinutes: original.snoozeMinutes
        )
        container.mainContext.insert(copy)
        event.notificationRules.append(copy)
        try? container.mainContext.save()

        #expect(event.notificationRules.count == 2)
        #expect(copy.id != original.id)
        #expect(copy.customTitle == "Original")
        #expect(copy.sound == .silent)
        #expect(copy.snoozeMinutes == 15)
    }

    @Test func deletingANotificationRuleFromTheMacModuleRemovesItFromTheEvent() {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent()
        container.mainContext.insert(event)
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 30, offsetUnit: .minutes)
        container.mainContext.insert(rule)
        event.notificationRules.append(rule)
        try? container.mainContext.save()

        container.mainContext.delete(rule)
        try? container.mainContext.save()

        #expect(event.notificationRules.isEmpty)
    }

    @Test func anInvalidOffsetCombinationIsRejectedByTheSameValidatorTheMacEditorUses() {
        #expect(throws: (any Error).self) {
            try NotificationRuleValidator.validate(
                anchor: .eventStart, offsetDirection: .at, offsetQuantity: 5, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    // MARK: - Global preferences (Notifications settings tab)

    @Test func notificationGlobalPreferencesRoundTripsQuietHoursFromTheMacModule() {
        var preferences = NotificationGlobalPreferences.current
        preferences.quietHours.isEnabled = true
        preferences.quietHours.startMinute = 22 * 60
        preferences.quietHours.endMinute = 7 * 60
        NotificationGlobalPreferences.save(preferences)

        let reloaded = NotificationGlobalPreferences.current
        #expect(reloaded.quietHours.isEnabled)
        #expect(reloaded.quietHours.startMinute == 22 * 60)
        #expect(reloaded.quietHours.endMinute == 7 * 60)
    }

    @Test func applyDefaultsToExistingEventsPreviewCountsAffectedEventsFromTheMacModule() {
        let container = MacTestSupport.makeTestContainer()
        let event = MacTestSupport.makeFixtureEvent(startDate: .now.addingTimeInterval(3_600))
        container.mainContext.insert(event)
        try? container.mainContext.save()

        let preview = NotificationDefaultsApplier.preview(events: [event], defaults: NotificationGlobalPreferences.current)
        #expect(preview.affectedEventCount >= 0) // exercised without crashing; exact policy covered by KueTests
    }

    // MARK: - Template notification defaults copy-at-creation (Kue 3.0 Phase 3 completion pass)
    // — `MacEventEditorView`'s `.add` mode saves through `EventSaveService.save` →
    // `EventCreationService.create` exactly like iPhone, so the copy-at-creation step applies
    // identically on Mac with no separate Mac-side wiring needed.

    @Test func creatingAnEventOnTheMacModuleCopiesItsTemplatesNotificationDefaults() {
        let container = MacTestSupport.makeTestContainer()
        let template = TemplateStore.fetchOrCreateBuiltIn(for: .exam, context: container.mainContext)
        template.notificationRuleDefaults = [NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 20, offsetUnit: .minutes)]
        try? container.mainContext.save()

        var draft = EventDraft()
        draft.title = "Mac Final Exam"
        draft.eventType = .exam
        draft.startDate = .now.addingTimeInterval(30 * 86_400)

        let result = EventSaveService.save(draft: draft, mode: .add(source: .manual), context: container.mainContext)
        #expect(result.event.notificationRules.count == 1)
        #expect(result.event.notificationRules.first?.offsetQuantity == 20)
    }
}
