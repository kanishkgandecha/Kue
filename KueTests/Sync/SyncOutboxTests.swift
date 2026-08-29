//
//  SyncOutboxTests.swift
//  KueTests
//
//  Kue 2.0 Phase 11 — docs/26 "S." 18–21 — offline create/edit/delete, multiple offline edits
//  collapsing, delete-before-unsent-create, tombstone retention.
//

import Testing
import Foundation
@testable import Kue

struct SyncOutboxTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: 18/19 — offline create/edit/delete; multiple edits collapse

    @Test func multipleOfflineEditsCollapseToOnePendingUpload() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDirty(eventID, store: store)
        SyncOutbox.markEventDirty(eventID, store: store)
        SyncOutbox.markEventDirty(eventID, store: store)
        #expect(store.load().pendingEventUploads == [eventID])
    }

    @Test func offlineDeleteRecordsATombstoneAndClearsAnyPendingUpload() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDirty(eventID, store: store)
        SyncOutbox.markEventDeleted(eventID, now: now, store: store)
        let state = store.load()
        #expect(state.pendingEventUploads.isEmpty)
        #expect(state.pendingEventDeletions == [eventID])
        #expect(state.eventTombstones[eventID] == now)
    }

    @Test func editAfterAnUnsentDeleteSupersedesTheDeletion() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDeleted(eventID, now: now, store: store)
        SyncOutbox.markEventDirty(eventID, store: store)
        let state = store.load()
        #expect(state.pendingEventUploads == [eventID])
        #expect(state.pendingEventDeletions.isEmpty)
    }

    // MARK: 20 — delete before unsent create

    @Test func discardNeverUploadedClearsBothQueuesWithNoTombstone() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDirty(eventID, store: store)
        SyncOutbox.discardNeverUploaded(eventID, store: store)
        let state = store.load()
        #expect(state.pendingEventUploads.isEmpty)
        #expect(state.pendingEventDeletions.isEmpty)
        #expect(state.eventTombstones[eventID] == nil)
    }

    // MARK: Pending count

    @Test func pendingChangeCountSumsEveryQueue() {
        let store = FakeCloudSyncStateStore()
        SyncOutbox.markEventDirty(UUID(), store: store)
        SyncOutbox.markEventDirty(UUID(), store: store)
        SyncOutbox.markEventDeleted(UUID(), now: now, store: store)
        SyncOutbox.markExclusionDirty(UUID(), store: store)
        #expect(SyncOutbox.pendingChangeCount(store: store) == 4)
    }

    // MARK: Tombstone retention

    @Test func tombstonesWithinRetentionWindowSurvivePruning() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDeleted(eventID, now: now, store: store)
        let pruned = SyncOutbox.pruneExpiredTombstones(now: now.addingTimeInterval(60), store: store)
        #expect(pruned == 0)
        #expect(store.load().eventTombstones[eventID] != nil)
    }

    @Test func tombstonesPastRetentionWindowArePruned() {
        let store = FakeCloudSyncStateStore()
        let eventID = UUID()
        SyncOutbox.markEventDeleted(eventID, now: now, store: store)
        let farFuture = now.addingTimeInterval(SyncOutbox.tombstoneRetention + 86_400)
        let pruned = SyncOutbox.pruneExpiredTombstones(now: farFuture, store: store)
        #expect(pruned == 1)
        #expect(store.load().eventTombstones[eventID] == nil)
    }

    // MARK: Durability — persists across "process relaunch" (a fresh store instance for a
    // real file-backed store; here, proving the state a fresh `SystemCloudSyncStateStore`
    // instance reads back matches what an earlier instance wrote to the same file).

    @Test func systemStateStorePersistsAcrossInstances() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncStateTest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let eventID = UUID()
        let firstInstance = SystemCloudSyncStateStore(fileURL: fileURL)
        SyncOutbox.markEventDirty(eventID, store: firstInstance)

        let secondInstance = SystemCloudSyncStateStore(fileURL: fileURL)
        #expect(secondInstance.load().pendingEventUploads == [eventID])
    }
}
