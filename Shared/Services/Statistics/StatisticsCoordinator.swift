//
//  StatisticsCoordinator.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Refresh behavior"/"Transport and synchronization." The one
//  orchestrator for the *cloud* half of statistics — app-only, `@MainActor` implicitly (this
//  module's own `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), same shape `SyncCoordinator`
//  already establishes. The *local* half needs no coordinator at all: every screen reads
//  `ProfileStatisticsEngine.compute(events:now:calendar:)` directly against a `@Query`-fetched
//  `[KueEvent]`, which SwiftData already re-invokes on every relevant local change for free
//  (requirement I: "avoid adding dozens of duplicated refresh calls" — the *local* dashboard
//  needs zero of them; only the debounced cloud upload needs a bounded set of trigger points).
//
//  Deliberately separate from `SyncCoordinator` — requirement E: "do not mix aggregate-
//  statistics cursors or state into the event graph synchronization protocol." The two are
//  called from the same handful of trigger sites (`RootTabView`'s account-state observer,
//  `BackgroundRefreshHandler`, backup restore, an explicit user action) as independent,
//  sibling passes, never chained through one another's internals.
//

import Foundation
import Observation

@MainActor
@Observable
final class StatisticsCoordinator {
    /// A `var`, not `let` — mirrors `SyncCoordinator.shared`'s own test-swap pattern.
    static var shared = StatisticsCoordinator()

    let stateStore: CloudStatisticsStatePersisting
    private let transport: StatisticsTransporting

    private(set) var status: CloudStatisticsStatus = .localOnly
    private var isRefreshing = false
    /// Requirement E: "account switching must never upload one account's aggregates to
    /// another account" — same guard shape `SyncCoordinator.lastSyncedAccountID` uses.
    private var lastUploadedAccountID: UUID?

    init(stateStore: CloudStatisticsStatePersisting = SystemCloudStatisticsStateStore.shared, transport: StatisticsTransporting = StatisticsCoordinator.defaultTransport) {
        self.stateStore = stateStore
        self.transport = transport
    }

    nonisolated private static var defaultTransport: StatisticsTransporting {
        SupabaseConfiguration.current.map { SupabaseStatisticsTransport(configuration: $0) } ?? NullStatisticsTransport()
    }

    /// Must match `UITestLaunchConfiguration.fakeStatisticsArgument` (KueUITests/) exactly.
    static let uiTestLaunchArgument = "-uiTestFakeStatistics"

    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> StatisticsCoordinator? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        return StatisticsCoordinator(stateStore: FakeCloudStatisticsStateStore(), transport: FakeStatisticsTransport())
    }

    /// The one entry point every trigger (account sign-in, background refresh, backup restore,
    /// an explicit "Update Now") calls. Reentrancy-safe, like `SyncCoordinator.sync`. Computes
    /// the current snapshot itself from the caller's already-fetched `events` — never opens or
    /// owns a `ModelContext` of its own, matching every other coordinator in this codebase.
    @discardableResult
    func refreshCloudUpload(events: [KueEvent], account: AccountCoordinator, now: Date = .now, calendar: Calendar = .current) async -> CloudStatisticsStatus {
        guard CloudStatisticsPreference.current.isEnabled else {
            status = .localOnly
            return status
        }
        guard !isRefreshing else { return status }
        isRefreshing = true
        defer { isRefreshing = false }

        guard case .signedIn(let session, _) = account.state else {
            status = .signInRequired
            return status
        }

        if let systemStore = stateStore as? SystemCloudStatisticsStateStore, systemStore.currentAccountID != session.user.id {
            systemStore.currentAccountID = session.user.id
        }
        if let lastUploadedAccountID, lastUploadedAccountID != session.user.id {
            // A different account just signed in on this device — never carry Account A's
            // "already uploaded this" bookkeeping into Account B's own pass (it would
            // incorrectly skip Account B's very first real upload as if it were a duplicate).
            stateStore.save(CloudStatisticsPersistentState())
        }
        lastUploadedAccountID = session.user.id

        guard let activeSession = await account.refreshIfNeeded() else {
            status = .signInRequired
            return status
        }

        guard let bucketStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            status = .error("Couldn't determine the current week.")
            return status
        }
        let statistics = ProfileStatisticsEngine.compute(events: events, now: now, calendar: calendar)
        let payload = StatisticsAggregatePayload.make(from: statistics, bucketStart: bucketStart, calendar: calendar)

        var state = stateStore.load()
        guard state.lastUploadedPayload != payload else {
            // Requirement I: "debounce cloud aggregate uploads where appropriate" — nothing
            // has changed since the last successful upload (same week, identical numbers);
            // skip the network call entirely rather than re-sending an unchanged snapshot.
            status = .upToDate(at: state.lastUploadedAt ?? now)
            return status
        }

        status = .uploading
        switch await transport.upload(payload, accessToken: activeSession.accessToken) {
        case .success:
            state.lastUploadedPayload = payload
            state.lastUploadedAt = now
            stateStore.save(state)
            status = .upToDate(at: now)
        case .failure(let error):
            status = Self.status(for: error)
        }
        return status
    }

    /// Requirement F: "Delete Cloud Statistics." Never touches the account itself or any local
    /// event/task — only this account's own previously-uploaded aggregate rows.
    @discardableResult
    func deleteCloudStatistics(account: AccountCoordinator) async -> Bool {
        guard case .signedIn = account.state, let activeSession = await account.refreshIfNeeded() else { return false }
        guard case .success = await transport.deleteAll(accessToken: activeSession.accessToken, userID: activeSession.user.id) else {
            return false
        }
        stateStore.save(CloudStatisticsPersistentState())
        status = .localOnly
        return true
    }

    /// Called once, immediately when the preference is turned off — requirement F: "turning
    /// cloud statistics off must stop future uploads." Never deletes anything already
    /// uploaded (that's the separate, explicit "Delete Cloud Statistics" action above); this
    /// only stops this device from uploading again until re-enabled.
    func handlePreferenceDisabled() {
        status = .localOnly
    }

    private static func status(for error: SyncTransportError) -> CloudStatisticsStatus {
        switch error {
        case .notAuthenticated, .sessionExpired: return .signInRequired
        case .networkUnavailable, .networkFailure, .serviceUnavailable: return .offline
        case .rateLimited: return .offline
        default: return .error("Couldn't update cloud statistics. It'll retry automatically.")
        }
    }
}
