//
//  SyncOutbox.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33. The one API every mutation call site (app, widgets, Share
//  Extension, App Intents, notification actions) uses to durably record "this event/
//  exclusion/notification-rule changed, sync it eventually" — never a direct
//  `SyncStatePersisting.save(_:)` call scattered across every mutation site. Renamed/extended
//  from Kue 2.0 Phase 11's `SyncOutbox` (docs/26 "E.") — the event/exclusion half is unchanged
//  in shape, just retargeted at the renamed store type; the notification-rule half is new.
//

import Foundation

nonisolated enum SyncOutbox {
    /// Call once, immediately after a local SwiftData save already succeeded — a local mutation
    /// must remain successful even if enqueueing or the eventual push fails, so this itself
    /// must never be able to invalidate work already on disk; at worst a write here silently
    /// no-ops (`SyncStatePersisting`'s own implementations already degrade that way).
    static func markEventDirty(_ eventID: UUID, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.insert(eventID)
        state.pendingEventDeletions.remove(eventID) // an edit after a not-yet-sent delete supersedes it
        store.save(state)
    }

    static func markEventDeleted(_ eventID: UUID, now: Date, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.remove(eventID)
        state.pendingEventDeletions.insert(eventID)
        state.eventTombstones[eventID] = now
        store.save(state)
    }

    static func markExclusionDirty(_ exclusionID: UUID, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingExclusionUploads.insert(exclusionID)
        store.save(state)
    }

    /// Requirement I: notification rules get their own explicit tombstone, never inferred from
    /// being absent from their owning event's next graph push. Also marks the owning event
    /// dirty — its *live* rule set (the survivors) travels embedded in that event's next graph
    /// push, exactly like task edits already do (`EventSyncRecord.notificationRules`).
    static func markNotificationRuleDeleted(_ ruleID: UUID, owningEventID: UUID?, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingNotificationRuleDeletions.insert(ruleID)
        if let owningEventID {
            state.pendingEventUploads.insert(owningEventID)
        }
        store.save(state)
    }

    /// A local event/task's notification rules changed (add/edit/duplicate, not delete) — the
    /// owning event's whole graph needs re-pushing so the new rule set travels with it.
    static func markNotificationRulesDirty(owningEventID: UUID, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.insert(owningEventID)
        store.save(state)
    }

    /// docs/26 "J.": "delete after an unsent create" — deleting an event that was never even
    /// pushed yet needs no tombstone at all (the server never heard of it, so nothing could
    /// resurrect it) and no pending-deletion entry either. Call this instead of
    /// `markEventDeleted` when the caller already knows the event was never successfully
    /// pushed — `SyncCoordinator` is the one place that knows this.
    static func discardNeverUploaded(_ eventID: UUID, store: SyncStatePersisting = SystemSyncStateStore.shared) {
        var state = store.load()
        state.pendingEventUploads.remove(eventID)
        state.pendingEventDeletions.remove(eventID)
        state.knownEventRevisions.removeValue(forKey: eventID)
        store.save(state)
    }

    static func pendingChangeCount(store: SyncStatePersisting = SystemSyncStateStore.shared) -> Int {
        let state = store.load()
        return state.pendingEventUploads.count + state.pendingEventDeletions.count
            + state.pendingExclusionUploads.count + state.pendingNotificationRuleDeletions.count
    }

    /// A generous fixed window rather than any coordination with the server's own retention
    /// (which this device has no reliable way to introspect) — comfortably exceeds how long a
    /// device could plausibly stay offline and still be one Kue wants to protect against
    /// resurrecting a deletion for.
    static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    @discardableResult
    static func pruneExpiredTombstones(now: Date, store: SyncStatePersisting = SystemSyncStateStore.shared) -> Int {
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
