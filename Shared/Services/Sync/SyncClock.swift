//
//  SyncClock.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "R." Every sync-layer type takes `now`/a clock explicitly,
//  matching the `now: Date = .now` convention `EventStatusEngine`/`SchedulingEngine`/
//  `NotificationCandidateBuilder` already establish — deterministic tests, no real clock
//  dependency.
//

import Foundation

nonisolated protocol SyncClock: Sendable {
    var now: Date { get }
}

nonisolated struct SystemSyncClock: SyncClock {
    var now: Date { .now }
}

/// Test-only fixed/advanceable clock.
final class FakeSyncClock: SyncClock, @unchecked Sendable {
    var now: Date
    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }
}
