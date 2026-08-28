//
//  SyncConflictResolverTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "S." Exhaustive tests for the pure
//  conflict decision — see docs/26 "H." for the policy this proves.
//

import Testing
import Foundation
@testable import Kue

struct SyncConflictResolverTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRecord(id: UUID = UUID(), title: String = "Interview", updatedAt: Date) -> EventSyncRecord {
        EventSyncRecord(
            id: id, title: title, eventType: "interview", startDate: now, endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: updatedAt
        )
    }

    // MARK: 5/6/7 — initial sync

    @Test func localOnlyStaysLocal() {
        let record = makeRecord(updatedAt: now)
        let resolution = SyncConflictResolver.resolve(local: .record(record), remote: .unknown)
        #expect(resolution == .keepLocal)
    }

    @Test func cloudOnlyDownloads() {
        let record = makeRecord(updatedAt: now)
        let resolution = SyncConflictResolver.resolve(local: .absent, remote: .record(record))
        #expect(resolution == .applyRemote(record))
    }

    // MARK: 8/9/10 — same-UUID conflict

    @Test func localNewerWins() {
        let id = UUID()
        let local = makeRecord(id: id, updatedAt: now.addingTimeInterval(100))
        let remote = makeRecord(id: id, updatedAt: now)
        #expect(SyncConflictResolver.resolve(local: .record(local), remote: .record(remote)) == .keepLocal)
    }

    @Test func remoteNewerWins() {
        let id = UUID()
        let local = makeRecord(id: id, updatedAt: now)
        let remote = makeRecord(id: id, updatedAt: now.addingTimeInterval(100))
        #expect(SyncConflictResolver.resolve(local: .record(local), remote: .record(remote)) == .applyRemote(remote))
    }

    // MARK: 11 — equal-timestamp deterministic tie-break

    @Test func equalTimestampsAreResolvedDeterministicallyAndConsistentlyBothWays() {
        let id = UUID()
        let a = makeRecord(id: id, title: "Interview A", updatedAt: now)
        let b = makeRecord(id: id, title: "Interview B", updatedAt: now)

        let resolutionOnDeviceA = SyncConflictResolver.resolve(local: .record(a), remote: .record(b))
        let resolutionOnDeviceB = SyncConflictResolver.resolve(local: .record(b), remote: .record(a))

        // Whichever record content "wins," both devices must agree on it being the *same*
        // record — never device A keeping its own local copy while device B also keeps its
        // own local copy (that would silently diverge forever).
        let winnerOnA: EventSyncRecord = { if case .applyRemote(let r) = resolutionOnDeviceA { return r } else { return a } }()
        let winnerOnB: EventSyncRecord = { if case .applyRemote(let r) = resolutionOnDeviceB { return r } else { return b } }()
        #expect(winnerOnA == winnerOnB)
    }

    @Test func equalTimestampTieBreakIsStableAcrossRepeatedCalls() {
        let id = UUID()
        let a = makeRecord(id: id, title: "Interview A", updatedAt: now)
        let b = makeRecord(id: id, title: "Interview B", updatedAt: now)
        let first = SyncConflictResolver.resolve(local: .record(a), remote: .record(b))
        let second = SyncConflictResolver.resolve(local: .record(a), remote: .record(b))
        #expect(first == second)
    }

    // MARK: 12 — tombstone vs. older save

    @Test func tombstoneNewerThanLocalSaveDeletesLocal() {
        let record = makeRecord(updatedAt: now)
        let resolution = SyncConflictResolver.resolve(local: .record(record), remote: .tombstone(deletedAt: now.addingTimeInterval(100)))
        #expect(resolution == .deleteLocal)
    }

    @Test func tombstoneEqualToLocalSaveDeletesLocal() {
        // docs/26 "H.": "deletion tombstones take precedence over older saves" — a tie goes
        // to the tombstone, not the save.
        let record = makeRecord(updatedAt: now)
        let resolution = SyncConflictResolver.resolve(local: .record(record), remote: .tombstone(deletedAt: now))
        #expect(resolution == .deleteLocal)
    }

    // MARK: 13 — explicit restore vs. older tombstone

    @Test func localSaveNewerThanTombstoneRestoresLocal() {
        let record = makeRecord(updatedAt: now.addingTimeInterval(100))
        let resolution = SyncConflictResolver.resolve(local: .record(record), remote: .tombstone(deletedAt: now))
        #expect(resolution == .restoreLocal(record))
    }

    @Test func remoteEditNewerThanLocalTombstoneUndoesTheLocalDeletion() {
        let record = makeRecord(updatedAt: now.addingTimeInterval(100))
        let resolution = SyncConflictResolver.resolve(local: .tombstone(deletedAt: now), remote: .record(record))
        #expect(resolution == .applyRemote(record))
    }

    @Test func remoteEditOlderThanLocalTombstoneStaysDeleted() {
        let record = makeRecord(updatedAt: now)
        let resolution = SyncConflictResolver.resolve(local: .tombstone(deletedAt: now.addingTimeInterval(100)), remote: .record(record))
        #expect(resolution == .keepLocal)
    }

    // MARK: Absent/tombstone-only combinations

    @Test func absentLocalAgainstRemoteTombstoneStaysAbsent() {
        #expect(SyncConflictResolver.resolve(local: .absent, remote: .tombstone(deletedAt: now)) == .keepLocal)
    }

    @Test func bothTombstonedIsANoOp() {
        #expect(SyncConflictResolver.resolve(local: .tombstone(deletedAt: now), remote: .tombstone(deletedAt: now.addingTimeInterval(50))) == .keepLocal)
    }

    @Test func mismatchedIdentitiesNeverMix() {
        let local = makeRecord(id: UUID(), updatedAt: now)
        let remote = makeRecord(id: UUID(), updatedAt: now.addingTimeInterval(100))
        #expect(SyncConflictResolver.resolve(local: .record(local), remote: .record(remote)) == .keepLocal)
    }
}
