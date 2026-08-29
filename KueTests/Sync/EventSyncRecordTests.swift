//
//  EventSyncRecordTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26 "S." Encode/decode round trips, tolerant decoding, future-version
//  rejection, and enum-fallback policy for every synced record type.
//

import Testing
import Foundation
@testable import Kue

struct EventSyncRecordTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func makeFullRecord() -> EventSyncRecord {
        EventSyncRecord(
            id: UUID(), title: "CAT 2026", eventType: "exam", startDate: now, endDate: nil,
            estimatedDurationMinutes: 180, isAllDay: false, timeZoneIdentifier: "Asia/Kolkata",
            location: "Test Center", notes: "Bring ID", source: "manual", priority: "high",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: RecurrenceRulePayload(frequency: "weekly", interval: 1, endKind: "never", endDate: nil, endOccurrenceCount: nil),
            seriesID: UUID(), recurrenceAnchorDate: now, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil,
            tasks: [TaskSyncPayload(id: UUID(), title: "Review chapter 1", dueDate: now, isCompleted: false, completedAt: nil, offsetLabel: "3 days before", sortOrder: 0)],
            schedule: SchedulePayload(id: UUID(), templateType: "exam", rules: [ScheduleRulePayload(offset: DateComponents(day: -3), taskTitle: "Review", isTimeSensitive: false)], isCustom: false, generatedAt: now),
            widgetConfiguration: WidgetConfigurationPayload(id: UUID(), widgetType: "preparation", showLocation: true, isEnabled: true),
            createdAt: now, updatedAt: now
        )
    }

    // MARK: 1 — round trip

    @Test func fullRecordRoundTrips() throws {
        let record = makeFullRecord()
        let data = try encoder().encode(record)
        let decoded = try decoder().decode(EventSyncRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test func minimalRecordWithNoOptionalsRoundTrips() throws {
        let record = EventSyncRecord(
            id: UUID(), title: "Generic", eventType: "generic", startDate: now, endDate: nil,
            estimatedDurationMinutes: 0, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now
        )
        let data = try encoder().encode(record)
        let decoded = try decoder().decode(EventSyncRecord.self, from: data)
        #expect(decoded == record)
    }

    // MARK: 2 — missing optional fields (simulates an older, additive-only payload)

    @Test func missingOptionalFieldsDecodeToSafeDefaults() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","startDate":\(now.timeIntervalSince1970 * 1000)}
        """
        let decoded = try decoder().decode(EventSyncRecord.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.title == "")
        #expect(decoded.eventType == "generic")
        #expect(decoded.source == "manual")
        #expect(decoded.priority == "medium")
        #expect(decoded.tasks.isEmpty)
        #expect(decoded.isCancelled == false)
    }

    // MARK: 3 — unsupported future version

    @Test func futureFormatVersionThrowsAndNeverPartiallyDecodes() {
        let id = UUID()
        let json = """
        {"recordFormatVersion":999,"id":"\(id.uuidString)","title":"Future Shape","startDate":\(now.timeIntervalSince1970 * 1000)}
        """
        #expect(throws: SyncDecodingError.self) {
            try decoder().decode(EventSyncRecord.self, from: Data(json.utf8))
        }
    }

    @Test func currentFormatVersionDecodesFine() throws {
        let id = UUID()
        let json = """
        {"recordFormatVersion":\(SyncRecordFormat.currentEventFormatVersion),"id":"\(id.uuidString)","startDate":\(now.timeIntervalSince1970 * 1000)}
        """
        let decoded = try decoder().decode(EventSyncRecord.self, from: Data(json.utf8))
        #expect(decoded.id == id)
    }

    // MARK: 4 — stable UUID-to-record-name mapping (docs/26 "C.")

    @Test func recordIdentityIsTheEventsOwnStableUUIDNeverASecondIdentity() {
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now, estimatedDurationMinutes: 60, source: .manual)
        let record = EventGraphMapper.record(for: event)
        #expect(record.id == event.id)
    }

    // MARK: RecurrenceExclusion

    @Test func recurrenceExclusionRoundTrips() throws {
        let record = RecurrenceExclusionSyncRecord(id: UUID(), seriesID: UUID(), excludedAnchorDate: now)
        let data = try encoder().encode(record)
        let decoded = try decoder().decode(RecurrenceExclusionSyncRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test func recurrenceExclusionFutureVersionThrows() {
        let json = """
        {"recordFormatVersion":999,"id":"\(UUID().uuidString)","seriesID":"\(UUID().uuidString)","excludedAnchorDate":\(now.timeIntervalSince1970 * 1000)}
        """
        #expect(throws: SyncDecodingError.self) {
            try decoder().decode(RecurrenceExclusionSyncRecord.self, from: Data(json.utf8))
        }
    }
}
