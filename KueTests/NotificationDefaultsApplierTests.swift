//
//  NotificationDefaultsApplierTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Notification hierarchy": preview
//  before applying, preserve event-specific overrides, deterministic/testable.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct NotificationDefaultsApplierTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func makeEvent(context: ModelContext, title: String = "Event") -> KueEvent {
        let event = KueEvent(title: title, eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        context.insert(event)
        return event
    }

    /// Preservation is per-anchor, not per-event: an event that already customized its
    /// event-start reminder keeps that customization untouched, but can still gain the
    /// separate default outcome-follow-up if it never touched that anchor either — "preserve
    /// event-specific overrides" means never overwriting/duplicating an existing override,
    /// not "skip the whole event forever once anything about it is customized."
    @Test func previewCountsEventsMissingAtLeastOneDefaultAnchor() {
        let context = makeContext()
        let plain = makeEvent(context: context, title: "Plain")
        let partiallyCustomized = makeEvent(context: context, title: "Partially Customized")
        partiallyCustomized.notificationRules = [NotificationRule(event: partiallyCustomized, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 5, offsetUnit: .minutes)]
        let fullyCustomized = makeEvent(context: context, title: "Fully Customized")
        fullyCustomized.notificationRules = [
            NotificationRule(event: fullyCustomized, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 5, offsetUnit: .minutes),
            NotificationRule(event: fullyCustomized, anchor: .outcomeFollowUp, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes),
        ]

        let preview = NotificationDefaultsApplier.preview(events: [plain, partiallyCustomized, fullyCustomized], defaults: .conservativeDefault)
        #expect(preview.affectedEventCount == 2) // plain (both anchors) + partiallyCustomized (outcome only)
        #expect(preview.eventStartRulesToAdd == 1) // plain only
        #expect(preview.outcomeFollowUpRulesToAdd == 2) // plain + partiallyCustomized
    }

    @Test func applyNeverOverwritesAnExistingOverrideAndIsIdempotent() {
        let context = makeContext()
        let plain = makeEvent(context: context)
        let partiallyCustomized = makeEvent(context: context)
        let existingRule = NotificationRule(event: partiallyCustomized, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 5, offsetUnit: .minutes)
        partiallyCustomized.notificationRules = [existingRule]
        try? context.save()

        let changed = NotificationDefaultsApplier.apply(events: [plain, partiallyCustomized], defaults: .conservativeDefault, context: context)
        #expect(changed == 2)
        #expect(plain.notificationRules.contains { $0.anchor == .eventStart })
        #expect(plain.notificationRules.contains { $0.anchor == .outcomeFollowUp })
        // The existing event-start override is untouched — never overwritten, never duplicated —
        // but the missing outcome-follow-up anchor is still added alongside it.
        #expect(partiallyCustomized.notificationRules.count == 2)
        #expect(partiallyCustomized.notificationRules.contains { $0.id == existingRule.id && $0.offsetQuantity == 5 })
        #expect(partiallyCustomized.notificationRules.contains { $0.anchor == .outcomeFollowUp })

        // Idempotent: every event now has both default anchors, so applying again changes nothing.
        let secondChanged = NotificationDefaultsApplier.apply(events: [plain, partiallyCustomized], defaults: .conservativeDefault, context: context)
        #expect(secondChanged == 0)
        #expect(plain.notificationRules.count == 2)
        #expect(partiallyCustomized.notificationRules.count == 2)
    }

    @Test func disabledDefaultOutcomeFollowUpIsNotAdded() {
        let context = makeContext()
        let event = makeEvent(context: context)
        var defaults = NotificationGlobalPreferences.conservativeDefault
        defaults.defaultOutcomeFollowUpEnabled = false

        _ = NotificationDefaultsApplier.apply(events: [event], defaults: defaults, context: context)
        #expect(!event.notificationRules.contains { $0.anchor == .outcomeFollowUp })
        #expect(event.notificationRules.contains { $0.anchor == .eventStart })
    }
}
