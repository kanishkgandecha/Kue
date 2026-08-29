//
//  SyncOutbox.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "E." The one API every mutation call site (app, widgets, Share
//  Extension, App Intents, notification actions) uses to durably record "this event/exclusion
//  changed, sync it eventually" — never a direct `CloudSyncStatePersisting.save(_:)` call
//  scattered across every mutation site. A plain stateless enum over the injected store, same
//  shape `NotificationEngine`'s own static functions already use.
//

import Foundation

nonisolated enum SyncOutbox {
    /// Call once, immediately after a local SwiftData save already succeeded — docs/26
    /// primary guarantee: "A local mutation must remain successful if enqueueing or CloudKit
    /// transmission fails," so this itself must never be able to invalidate work already on
    /// disk; at worst a write here silently no-ops (`CloudSyncStatePersisting`'s own
    /// implementations already degrade that way).
    static func markEventDirty(_ eventID: UUID, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.insert(eventID)
        state.pendingEventDeletions.remove(eventID) // an edit after a not-yet-sent delete supersedes it
        store.save(state)
    }

    static func markEventDeleted(_ eventID: UUID, now: Date, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.remove(eventID)
        state.pendingEventDeletions.insert(eventID)
        state.eventTombstones[eventID] = now
        store.save(state)
    }

    static func markExclusionDirty(_ exclusionID: UUID, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) {
        var state = store.load()
        state.pendingExclusionUploads.insert(exclusionID)
        state.pendingExclusionDeletions.remove(exclusionID)
        store.save(state)
    }

    static func markExclusionDeleted(_ exclusionID: UUID, now: Date, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) {
        var state = store.load()
        state.pendingExclusionUploads.remove(exclusionID)
        state.pendingExclusionDeletions.insert(exclusionID)
        state.exclusionTombstones[exclusionID] = now
        store.save(state)
    }

    /// Kue 2.0 Phase 11 — docs/26 "J.": "delete after an unsent create" — deleting an event
    /// that was never even uploaded yet needs no tombstone at all (CloudKit never heard of it,
    /// so nothing could resurrect it) and no pending-deletion entry either (there's nothing to
    /// tell the server to delete). Call this instead of `markEventDeleted` when the caller
    /// already knows the event was never successfully uploaded — `SyncCoordinator` is the one
    /// place that knows this (it tracks acknowledged uploads), so this is exposed for it, not
    /// for ordinary mutation call sites (which always call `markEventDeleted`, the safe
    /// default when upload state isn't known locally).
    static func discardNeverUploaded(_ eventID: UUID, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.remove(eventID)
        state.pendingEventDeletions.remove(eventID)
        store.save(state)
    }

    static func pendingChangeCount(store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) -> Int {
        let state = store.load()
        return state.pendingEventUploads.count + state.pendingEventDeletions.count
            + state.pendingExclusionUploads.count + state.pendingExclusionDeletions.count
    }

    /// docs/26 "E.": "Define safe tombstone retention and cleanup. Do not delete tombstones
    /// until every reasonable synchronization requirement has been satisfied." A generous
    /// fixed window rather than any coordination with CloudKit's own change-token lifetime
    /// (which Kue's local state has no reliable way to introspect) — chosen to comfortably
    /// exceed how long a device could plausibly stay offline and still be a device Kue wants
    /// to protect against resurrecting a deletion for.
    static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    @discardableResult
    static func pruneExpiredTombstones(now: Date, store: CloudSyncStatePersisting = SystemCloudSyncStateStore.shared) -> Int {
        var state = store.load()
        let cutoff = now.addingTimeInterval(-tombstoneRetention)
        let beforeEvent = state.eventTombstones.count
        let beforeExclusion = state.exclusionTombstones.count
        state.eventTombstones = state.eventTombstones.filter { $0.value > cutoff }
        state.exclusionTombstones = state.exclusionTombstones.filter { $0.value > cutoff }
        let pruned = (beforeEvent - state.eventTombstones.count) + (beforeExclusion - state.exclusionTombstones.count)
        if pruned > 0 { store.save(state) }
        return pruned
    }
}
