//
//  BackupCoderTests.swift
//  KueTests
//
//  Kue 2.0 Phase 12 — docs/28 "G." Backup compatibility fixtures — 11 representative shapes,
//  built fresh in each test (no real user content, ever), each round-tripped through the real
//  export → validate → restore pipeline: a populated in-memory `ModelContext` → `BackupCoder.
//  exportData` → raw bytes → `BackupCoder.decodeAndValidate` → `BackupRestoreService.restore`
//  into a second, independent in-memory `ModelContext` → assert the restored side matches.
//  Corruption/version/malformed-payload cases (docs/28 "F.": "validate before deserializing")
//  and `BackupRestoreService`'s merge-by-UUID conflict policy get their own focused tests.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@Suite
@MainActor
struct BackupCoderTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    /// Exports `source`, validates the bytes, restores into a fresh empty context, and hands
    /// back that restored context for the caller to assert against — the one path every
    /// fixture test below drives.
    private func roundTrip(_ source: ModelContext) async throws -> ModelContext {
        let data = try BackupCoder.exportData(context: source, exportedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "test")
        let (_, payload) = try BackupCoder.decodeAndValidate(data)
        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)
        return destination
    }

    // MARK: - 1. Empty store

    @Test func emptyStoreRoundTripsToAnEmptyStore() async throws {
        let destination = try await roundTrip(makeContext())
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).isEmpty)
    }

    // MARK: - 2. Single minimal event, every optional field nil

    @Test func minimalEventWithNoOptionalFieldsRoundTrips() async throws {
        let source = makeContext()
        source.insert(KueEvent(title: "Minimal", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual))
        try source.save()

        let destination = try await roundTrip(source)
        let events = try destination.fetch(FetchDescriptor<KueEvent>())
        #expect(events.count == 1)
        #expect(events.first?.title == "Minimal")
        #expect(events.first?.location == nil)
        #expect(events.first?.notes == nil)
    }

    // MARK: - 3. Event with tasks

    @Test func eventWithTasksRoundTripsAllOfThem() async throws {
        let source = makeContext()
        let event = KueEvent(title: "With Tasks", eventType: .deadline, startDate: .now, estimatedDurationMinutes: 0, source: .manual)
        event.tasks = [
            KueTask(event: event, title: "Step 1", dueDate: .now, offsetLabel: "2 days before", sortOrder: 0),
            KueTask(event: event, title: "Step 2", dueDate: .now, offsetLabel: "1 day before", sortOrder: 1)
        ]
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<KueEvent>()).first
        #expect(restored?.tasks.count == 2)
    }

    // MARK: - 4. Event with a schedule

    @Test func eventWithScheduleRoundTrips() async throws {
        let source = makeContext()
        let event = KueEvent(title: "With Schedule", eventType: .exam, startDate: .now, estimatedDurationMinutes: 60, source: .manual)
        event.schedule = KueSchedule(event: event, templateType: .exam, rules: [ScheduleRule(offset: DateComponents(day: -2), taskTitle: "Review notes", isTimeSensitive: false)])
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<KueEvent>()).first
        #expect(restored?.schedule?.rules.count == 1)
    }

    // MARK: - 5. Event with a widget configuration

    @Test func eventWithWidgetConfigurationRoundTrips() async throws {
        let source = makeContext()
        let event = KueEvent(title: "With Widget", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual)
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .progress, showLocation: false, isEnabled: true)
        source.insert(event)
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<KueEvent>()).first
        #expect(restored?.widgetConfiguration?.widgetType == .progress)
        #expect(restored?.widgetConfiguration?.showLocation == false)
    }

    // MARK: - 6. Recurring event with a recurrence exclusion

    @Test func recurringEventAndItsExclusionRoundTrip() async throws {
        let source = makeContext()
        let seriesID = UUID()
        let event = KueEvent(
            title: "Weekly", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual,
            recurrence: RecurrenceRule(frequency: .weekly, interval: 1, end: .never),
            seriesID: seriesID, recurrenceAnchorDate: .now
        )
        source.insert(event)
        source.insert(RecurrenceExclusion(seriesID: seriesID, excludedAnchorDate: Date(timeIntervalSince1970: 1_700_100_000)))
        try source.save()

        let destination = try await roundTrip(source)
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).first?.recurrence?.frequency == .weekly)
        #expect(try destination.fetch(FetchDescriptor<RecurrenceExclusion>()).count == 1)
    }

    // MARK: - 7. All-day event

    @Test func allDayEventPreservesTheAllDayFlag() async throws {
        let source = makeContext()
        source.insert(KueEvent(title: "All Day", eventType: .trip, startDate: .now, endDate: .now.addingTimeInterval(86400), estimatedDurationMinutes: 0, isAllDay: true, source: .manual))
        try source.save()

        let destination = try await roundTrip(source)
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).first?.isAllDay == true)
    }

    // MARK: - 8. Event with every populated optional field

    @Test func fullyPopulatedEventRoundTripsEveryField() async throws {
        let source = makeContext()
        source.insert(KueEvent(
            title: "Fully Populated", eventType: .interview, startDate: .now, estimatedDurationMinutes: 45,
            location: "123 Main St", notes: "Bring resume", source: .manual, priority: .high
        ))
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<KueEvent>()).first
        #expect(restored?.location == "123 Main St")
        #expect(restored?.notes == "Bring resume")
        #expect(restored?.priority == .high)
    }

    // MARK: - 9. Cancelled and manually-completed events

    @Test func cancelledAndManuallyCompletedFlagsRoundTrip() async throws {
        let source = makeContext()
        source.insert(KueEvent(title: "Cancelled", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual, isCancelled: true, cancelledAt: .now))
        source.insert(KueEvent(title: "Completed", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual, isManuallyCompleted: true, manuallyCompletedAt: .now))
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<KueEvent>())
        #expect(restored.contains { $0.isCancelled })
        #expect(restored.contains { $0.isManuallyCompleted })
    }

    // MARK: - 10. Template

    @Test func templateRoundTrips() async throws {
        let source = makeContext()
        source.insert(Template(name: "Standard Exam Prep", eventType: .exam, scheduleRules: [ScheduleRule(offset: DateComponents(day: -3), taskTitle: "Start reviewing", isTimeSensitive: false)], isBuiltIn: true))
        try source.save()

        let destination = try await roundTrip(source)
        let templates = try destination.fetch(FetchDescriptor<Template>())
        #expect(templates.count == 1)
        #expect(templates.first?.name == "Standard Exam Prep")
    }

    // MARK: - 11. Non-default user preference

    @Test func userPreferenceRoundTrips() async throws {
        let source = makeContext()
        let preference = UserPreferenceStore.current(context: source)
        preference.notificationIntensity = .minimal
        preference.aiParsingEnabled = false
        try source.save()

        let destination = try await roundTrip(source)
        let restored = try destination.fetch(FetchDescriptor<UserPreference>()).first
        #expect(restored?.notificationIntensity == .minimal)
        #expect(restored?.aiParsingEnabled == false)
    }

    // MARK: - Validation (docs/28 "F.": checked before any SwiftData deserialization)

    @Test func garbageDataIsRejectedAsNotABackupFile() {
        #expect(throws: BackupError.notABackupFile) {
            _ = try BackupCoder.decodeAndValidate(Data("not json at all".utf8))
        }
    }

    @Test func tamperedPayloadFailsChecksumValidation() throws {
        let data = try BackupCoder.exportData(context: makeContext())
        var envelope = try JSONDecoder.kueBackupDecoder.decode(BackupEnvelope.self, from: data)
        // Flip the payload bytes without recomputing the checksum — simulates corruption or a
        // hand-edited file, exactly what `checksum` exists to catch.
        envelope.payload = Data("tampered".utf8)
        let tamperedData = try JSONEncoder.kueBackupEncoder.encode(envelope)

        #expect(throws: BackupError.checksumMismatch) {
            _ = try BackupCoder.decodeAndValidate(tamperedData)
        }
    }

    @Test func futureFormatVersionIsRejectedRatherThanGuessedAt() throws {
        let payload = try BackupCoder.exportPayload(context: makeContext())
        let payloadData = try JSONEncoder.kueBackupEncoder.encode(payload)
        let envelope = BackupEnvelope(formatVersion: BackupFormat.currentVersion + 1, exportedAt: Date(), exportedByAppVersion: "test", payload: payloadData)
        let data = try JSONEncoder.kueBackupEncoder.encode(envelope)

        #expect(throws: BackupError.unsupportedFutureFormatVersion(found: BackupFormat.currentVersion + 1, maxSupported: BackupFormat.currentVersion)) {
            _ = try BackupCoder.decodeAndValidate(data)
        }
    }

    // MARK: - Restore merge policy (reuses SyncConflictResolver — see BackupRestoreService.swift)

    @Test func restoringOverAnExistingNewerEventKeepsTheLocalOne() async throws {
        let id = UUID()
        let backupSource = makeContext()
        backupSource.insert(KueEvent(id: id, title: "Old Title", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual, updatedAt: Date(timeIntervalSince1970: 1_000)))
        try backupSource.save()
        let data = try BackupCoder.exportData(context: backupSource)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = makeContext()
        destination.insert(KueEvent(id: id, title: "New Title", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual, updatedAt: Date(timeIntervalSince1970: 2_000)))
        try destination.save()

        let summary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(summary.eventsSkippedAsOlder == 1)
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).first?.title == "New Title")
    }

    @Test func restoringAnOlderBackupIntoAnEmptyStoreInsertsEverything() async throws {
        let source = makeContext()
        source.insert(KueEvent(title: "Brought Back", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual))
        try source.save()
        let data = try BackupCoder.exportData(context: source)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = makeContext()
        let summary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(summary.eventsInserted == 1)
        #expect(try destination.fetch(FetchDescriptor<KueEvent>()).count == 1)
    }

    @Test func restoringTwiceNeverDuplicatesExclusionsOrTemplates() async throws {
        let source = makeContext()
        source.insert(RecurrenceExclusion(seriesID: UUID(), excludedAnchorDate: .now))
        source.insert(Template(name: "T", eventType: .generic, isBuiltIn: true))
        try source.save()
        let data = try BackupCoder.exportData(context: source)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination)
        let secondSummary = try await BackupRestoreService.restore(payload: payload, context: destination)
        #expect(secondSummary.exclusionsInserted == 0)
        #expect(secondSummary.templatesInserted == 0)
        #expect(try destination.fetch(FetchDescriptor<RecurrenceExclusion>()).count == 1)
        #expect(try destination.fetch(FetchDescriptor<Template>()).count == 1)
    }

    // MARK: - Post-restore reconciliation

    /// `EventSyncRecord`/`BackupPayload` never carries `status` (it's derived, docs/26 "I."), so
    /// `EventGraphMapper.makeEvent(from:)` always constructs a freshly-restored event at its
    /// `KueEvent.init` default, `.upcoming` — regardless of whether the real date has already
    /// passed. `BackupRestoreService.restore` must run the same reconciliation pass every other
    /// mutation surface triggers so a restored past-due event doesn't sit at `.upcoming`
    /// forever; this proves that actually happens, not just that reconciliation is called.
    @Test func restoringAPastDueEventCorrectsItsStatusRatherThanLeavingTheDefault() async throws {
        let source = makeContext()
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        source.insert(KueEvent(title: "Long Overdue", eventType: .generic, startDate: past, estimatedDurationMinutes: 30, source: .manual))
        try source.save()
        let data = try BackupCoder.exportData(context: source, exportedAt: past)
        let (_, payload) = try BackupCoder.decodeAndValidate(data)

        let destination = makeContext()
        _ = try await BackupRestoreService.restore(payload: payload, context: destination, now: past.addingTimeInterval(30 * 86_400))

        let restored = try destination.fetch(FetchDescriptor<KueEvent>()).first
        #expect(restored?.status == .awaitingOutcome)
    }

    /// docs/28 "B.": restore is transactional in the sense that matters — nothing is written to
    /// the destination context until the single `context.save()` at the end of `restore`, so a
    /// payload that fails validation never reaches `BackupRestoreService` at all, and existing
    /// data a caller already had is never touched by a validation failure.
    @Test func aRejectedBackupNeverTouchesExistingData() async throws {
        let destination = makeContext()
        destination.insert(KueEvent(title: "Untouched", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual))
        try destination.save()

        #expect(throws: BackupError.self) {
            _ = try BackupCoder.decodeAndValidate(Data("not a backup".utf8))
        }

        let events = try destination.fetch(FetchDescriptor<KueEvent>())
        #expect(events.count == 1)
        #expect(events.first?.title == "Untouched")
    }
}
