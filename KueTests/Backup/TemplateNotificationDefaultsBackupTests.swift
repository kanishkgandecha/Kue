//
//  TemplateNotificationDefaultsBackupTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults": export/import of
//  `Template.notificationRuleDefaults`, invalid-row rejection, and pre-completion-pass (no
//  `notificationRuleDefaults` field at all) backups still importing cleanly. Reuses
//  `BackupCoderTests`' own `roundTrip` shape rather than re-deriving it.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite
@MainActor
struct TemplateNotificationDefaultsBackupTests {
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

    @Test func aTemplateWithNotificationDefaultsRoundTrips() async throws {
        let source = makeContext()
        let template = Template(
            name: "Standard Exam Prep", eventType: .exam,
            notificationRuleDefaults: [
                NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 30, offsetUnit: .minutes, customTitle: "Exam soon"),
                NotificationRuleDefault(anchor: .outcomeFollowUp, offsetDirection: .after, offsetQuantity: 1, offsetUnit: .days, snoozeMinutes: 15),
            ],
            isBuiltIn: true
        )
        source.insert(template)
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try #require(try destination.fetch(FetchDescriptor<Template>()).first)
        #expect(restored.notificationRuleDefaults.count == 2)
        #expect(restored.notificationRuleDefaults.contains { $0.anchor == .eventStart && $0.customTitle == "Exam soon" })
        #expect(restored.notificationRuleDefaults.contains { $0.anchor == .outcomeFollowUp && $0.snoozeMinutes == 15 })
    }

    @Test func aTemplateWithNoNotificationDefaultsRoundTripsAsEmpty() async throws {
        let source = makeContext()
        source.insert(Template(name: "Bare", eventType: .generic, isBuiltIn: true))
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try #require(try destination.fetch(FetchDescriptor<Template>()).first)
        #expect(restored.notificationRuleDefaults.isEmpty)
    }

    /// docs/31 "Template notification defaults" + backup compatibility: a template backed up
    /// before this completion pass never had a `notificationRuleDefaults` key at all — decoding
    /// must default to `[]`, not fail. Same discipline as
    /// `NotificationRuleBackupTests.aVersionOneBackupWithNoNotificationRulesFieldAtAllStillImportsCleanly`.
    @Test func aPreCompletionPassTemplateBackupWithNoNotificationDefaultsFieldAtAllStillImportsCleanly() async throws {
        let source = makeContext()
        source.insert(Template(name: "Pre-Completion-Pass Template", eventType: .generic, isBuiltIn: true))
        try source.save()
        let payload = try BackupCoder.exportPayload(context: source)

        var json = try JSONSerialization.jsonObject(with: JSONEncoder.kueBackupEncoder.encode(payload)) as! [String: Any]
        var templates = json["templates"] as! [[String: Any]]
        templates[0].removeValue(forKey: "notificationRuleDefaults")
        json["templates"] = templates
        let strippedPayloadData = try JSONSerialization.data(withJSONObject: json)
        let decodedPayload = try JSONDecoder.kueBackupDecoder.decode(BackupPayload.self, from: strippedPayloadData)
        #expect(decodedPayload.templates.first?.notificationRuleDefaults.isEmpty == true)

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: decodedPayload, context: destination)
        #expect(summary.templatesInserted == 1)
        let restored = try #require(try destination.fetch(FetchDescriptor<Template>()).first)
        #expect(restored.notificationRuleDefaults.isEmpty)
    }

    @Test func anInvalidNotificationDefaultIsRejectedWithoutBlockingTheTemplate() async throws {
        // `.at` direction with a nonzero offset — never producible by the real editor, but a
        // hand-edited/foreign backup file could carry it. Mirrors
        // `NotificationRuleBackupTests.anInvalidOffsetCombinationIsRejectedNotInserted`.
        let invalidDefault = NotificationRuleDefaultPayload(
            id: UUID(), anchor: "eventStart", offsetDirection: "at", offsetQuantity: 5, offsetUnit: "minutes",
            isEnabled: true, customTitle: nil, customBody: nil, sound: "defaultSound",
            interruptionPreference: "active", snoozeMinutes: nil
        )
        let templatePayload = TemplateBackupPayload(
            id: UUID(), name: "Has One Bad Rule", eventType: "generic", scheduleRules: [],
            isUserDefined: false, isBuiltIn: true, notificationRuleDefaults: [invalidDefault]
        )
        let payload = BackupPayload(events: [], exclusions: [], templates: [templatePayload], userPreference: nil)

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(summary.templatesInserted == 1)
        #expect(summary.templateNotificationDefaultsRejected == 1)
        let restored = try #require(try destination.fetch(FetchDescriptor<Template>()).first)
        #expect(restored.notificationRuleDefaults.isEmpty)
    }

    @Test func restoringTwiceNeverDuplicatesTheTemplateOrItsDefaults() async throws {
        let source = makeContext()
        source.insert(Template(
            name: "Standard Exam Prep", eventType: .exam,
            notificationRuleDefaults: [NotificationRuleDefault(anchor: .eventStart, offsetDirection: .before, offsetQuantity: 30, offsetUnit: .minutes)],
            isBuiltIn: true
        ))
        try source.save()

        let data = try BackupCoder.exportData(context: source, exportedAt: .now, appVersion: "test")
        let (_, payload) = try BackupCoder.decodeAndValidate(data)
        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)

        let templates = try destination.fetch(FetchDescriptor<Template>())
        #expect(templates.count == 1)
        #expect(templates.first?.notificationRuleDefaults.count == 1)
    }
}
