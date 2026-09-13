//
//  RecommendationDismissalStoreTests.swift
//  KueTests
//
//  Kue 3.0 Phase 8 — docs/36 "F. Dismissal expiry". Real App Group `UserDefaults` state
//  (`smartPlanning.dismissals.v1`), unique to this phase — no other suite touches this key, so
//  same-suite `.serialized` (not the cross-suite `.syncPreferenceSerialized` trait) is enough,
//  matching `EventActionsSyncOutboxTestLock`/`MigrationStoreTestLock`'s own "new, unshared key"
//  precedent. Every test resets the store first so ordering never matters.
//

import Testing
import Foundation
@testable import Kue

@Suite(.serialized)
struct RecommendationDismissalStoreTests {
    init() { RecommendationDismissalStore.resetAll() }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aFreshRecommendationIsNeverSuppressed() {
        #expect(!RecommendationDismissalStore.isSuppressed(id: "never-dismissed", now: now))
    }

    @Test func dismissingSuppressesImmediately() {
        RecommendationDismissalStore.dismiss(id: "rec-1", now: now)
        #expect(RecommendationDismissalStore.isSuppressed(id: "rec-1", now: now))
    }

    @Test func dismissalExpiresAfterItsWindow() {
        RecommendationDismissalStore.dismiss(id: "rec-1", now: now)
        let justBeforeExpiry = now.addingTimeInterval(RecommendationDismissalStore.dismissWindow - 1)
        let justAfterExpiry = now.addingTimeInterval(RecommendationDismissalStore.dismissWindow + 1)
        #expect(RecommendationDismissalStore.isSuppressed(id: "rec-1", now: justBeforeExpiry))
        #expect(!RecommendationDismissalStore.isSuppressed(id: "rec-1", now: justAfterExpiry))
    }

    @Test func snoozeSuppressesUntilTheExactRequestedDate() {
        let until = now.addingTimeInterval(3600)
        RecommendationDismissalStore.snooze(id: "rec-2", until: until, now: now)
        #expect(RecommendationDismissalStore.isSuppressed(id: "rec-2", now: now.addingTimeInterval(1800)))
        #expect(!RecommendationDismissalStore.isSuppressed(id: "rec-2", now: until.addingTimeInterval(1)))
    }

    /// docs/36: a recommendation `id` is content-derived, so a genuinely changed underlying
    /// task/event produces a *different* id — this is the mechanism, exercised directly here
    /// rather than through the whole engine.
    @Test func aDifferentIDIsUnaffectedByAnUnrelatedDismissal() {
        RecommendationDismissalStore.dismiss(id: "overdueTask-eventA-100", now: now)
        #expect(!RecommendationDismissalStore.isSuppressed(id: "overdueTask-eventA-101", now: now))
    }

    @Test func activeSuppressedIDsOnlyIncludesStillSuppressedEntries() {
        RecommendationDismissalStore.dismiss(id: "expired", now: now.addingTimeInterval(-RecommendationDismissalStore.dismissWindow - 10))
        RecommendationDismissalStore.dismiss(id: "active", now: now)
        let active = RecommendationDismissalStore.activeSuppressedIDs(now: now)
        #expect(active.contains("active"))
        #expect(!active.contains("expired"))
    }

    @Test func resetAllClearsEveryDismissal() {
        RecommendationDismissalStore.dismiss(id: "rec-1", now: now)
        RecommendationDismissalStore.dismiss(id: "rec-2", now: now)
        RecommendationDismissalStore.resetAll()
        #expect(RecommendationDismissalStore.count == 0)
        #expect(!RecommendationDismissalStore.isSuppressed(id: "rec-1", now: now))
    }
}
