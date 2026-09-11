//
//  NotificationRuleBackupTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Backup": export/import of
//  `NotificationRule`, merge by stable UUID, invalid-row rejection, reconciliation after
//  restore, and pre-Phase-3 (version-1) backups still importing cleanly with the global
//  defaults taking over. Reuses `BackupCoderTests`' own `roundTrip` shape rather than
//  re-deriving it.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite
@MainActor
struct NotificationRuleBackupTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    private func roundTrip(_ source: ModelContext) async throws -> ModelContext {
        let data = try BackupCoder.exportData(context: source, exportedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "test")
        let (_, payload) = try BackupCoder.decodeAndValidate(data)
        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)
        return destination
    }

    @Test func anEventLevelRuleRoundTrips() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes, customTitle: "Custom Title")
        event.notificationRules = [rule]
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restoredEvent = try #require(try destination.fetch(FetchDescriptor<KueEvent>()).first)
        #expect(restoredEvent.notificationRules.count == 1)
        let restoredRule = try #require(restoredEvent.notificationRules.first)
        #expect(restoredRule.id == rule.id)
        #expect(restoredRule.anchor == .eventStart)
        #expect(restoredRule.offsetQuantity == 15)
        #expect(restoredRule.customTitle == "Custom Title")
    }

    @Test func aTaskLevelRulePreservesItsTaskRelationship() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        let task = KueTask(event: event, title: "Prep slides", dueDate: .now.addingTimeInterval(1800), offsetLabel: "soon")
        event.tasks = [task]
        let rule = NotificationRule(task: task, anchor: .taskDue, offsetDirection: .at, offsetQuantity: 0)
        task.notificationRules = [rule]
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restoredEvent = try #require(try destination.fetch(FetchDescriptor<KueEvent>()).first)
        let restoredTask = try #require(restoredEvent.tasks.first)
        #expect(restoredTask.notificationRules.count == 1)
        #expect(restoredTask.notificationRules.first?.anchor == .taskDue)
    }

    @Test func aRuleWhoseOwningEventIsMissingFromThisRestoreIsRejectedNotInserted() async throws {
        // Simulates a backup file edited/corrupted so a rule references an event UUID this
        // restore never actually inserts — docs/31: "Reject invalid anchors, offsets, and enum
        // values safely" extends to a structurally-orphaned relationship too.
        let orphanEventID = UUID()
        let orphanRule = NotificationRulePayload(
            id: UUID(), eventID: orphanEventID, taskID: nil, anchor: "eventStart", offsetDirection: "before",
            offsetQuantity: 10, offsetUnit: "minutes", absoluteDate: nil, isEnabled: true,
            customTitle: nil, customBody: nil, sound: "defaultSound", interruptionPreference: "active",
            snoozeMinutes: nil, sortOrder: 0, createdAt: .now, updatedAt: .now
        )
        let payload = BackupPayload(events: [], exclusions: [], templates: [], userPreference: nil, notificationRules: [orphanRule])

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(summary.notificationRulesRejected == 1)
        #expect(summary.notificationRulesInserted == 0)
        #expect(try destination.fetch(FetchDescriptor<NotificationRule>()).isEmpty)
    }

    @Test func anInvalidOffsetCombinationIsRejectedNotInserted() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        source.insert(event)
        try source.save()
        let eventPayload = EventGraphMapper.record(for: event)

        // `.at` direction with a nonzero offset — never producible by the real editor, but a
        // hand-edited/foreign backup file could carry it.
        let invalidRule = NotificationRulePayload(
            id: UUID(), eventID: event.id, taskID: nil, anchor: "eventStart", offsetDirection: "at",
            offsetQuantity: 5, offsetUnit: "minutes", absoluteDate: nil, isEnabled: true,
            customTitle: nil, customBody: nil, sound: "defaultSound", interruptionPreference: "active",
            snoozeMinutes: nil, sortOrder: 0, createdAt: .now, updatedAt: .now
        )
        let payload = BackupPayload(events: [eventPayload], exclusions: [], templates: [], userPreference: nil, notificationRules: [invalidRule])

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(summary.notificationRulesRejected == 1)
        #expect(try destination.fetch(FetchDescriptor<NotificationRule>()).isEmpty)
        // The event itself still restores fine — one bad rule never blocks the rest.
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).count == 1)
    }

    @Test func restoringTwiceNeverDuplicatesTheSameRule() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        event.notificationRules = [NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes)]
        source.insert(event)
        try source.save()

        let data = try BackupCoder.exportData(context: source, exportedAt: .now, appVersion: "test")
        let (_, payload) = try BackupCoder.decodeAndValidate(data)
        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)

        #expect(try destination.fetch(FetchDescriptor<NotificationRule>()).count == 1)
    }

    /// docs/31 "Backup": "Older backups remain importable with sensible default rules." A
    /// version-1 payload (pre-Phase-3) never had `notificationRules` in its JSON at all —
    /// decoding must default to `[]`, not fail, and the restored event simply falls back to
    /// global-default notification behavior (nothing this test needs to assert on directly,
    /// since the planner — not the backup format — owns that fallback; see
    /// `NotificationPlannerTests`).
    @Test func aVersionOneBackupWithNoNotificationRulesFieldAtAllStillImportsCleanly() async throws {
        let source = makeContext()
        source.insert(KueEvent(title: "Pre-Phase-3 Event", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual))
        try source.save()
        let payload = try BackupCoder.exportPayload(context: source)

        // Encode via a JSON object with the `notificationRules` key stripped entirely,
        // simulating a genuine version-1 payload rather than just passing an empty array
        // (which the tolerant decoder would trivially accept regardless).
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.kueBackupEncoder.encode(payload)) as! [String: Any]
        json.removeValue(forKey: "notificationRules")
        let strippedPayloadData = try JSONSerialization.data(withJSONObject: json)
        let decodedPayload = try JSONDecoder.kueBackupDecoder.decode(BackupPayload.self, from: strippedPayloadData)
        #expect(decodedPayload.notificationRules.isEmpty)

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: decodedPayload, context: destination)
        #expect(summary.eventsInserted == 1)
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).count == 1)
    }

    // MARK: - Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze": "Test backup
    // round-trip" for `snoozeMinutes` specifically, not just incidentally alongside other fields.

    @Test func aRulesExplicitSnoozeMinutesRoundTrips() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        event.notificationRules = [NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes, snoozeMinutes: 20)]
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restoredEvent = try #require(try destination.fetch(FetchDescriptor<KueEvent>()).first)
        #expect(restoredEvent.notificationRules.first?.snoozeMinutes == 20)
    }

    @Test func aRuleWithNoSnoozeMinutesRoundTripsAsNilNotZero() async throws {
        let source = makeContext()
        let event = KueEvent(title: "Board Review", eventType: .generic, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
        event.notificationRules = [NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 10, offsetUnit: .minutes, snoozeMinutes: nil)]
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restoredEvent = try #require(try destination.fetch(FetchDescriptor<KueEvent>()).first)
        #expect(restoredEvent.notificationRules.first?.snoozeMinutes == nil)
    }
}
