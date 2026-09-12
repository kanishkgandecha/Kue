//
//  StatisticsCoordinatorTests.swift
//  KueTests
//
//  Kue 3.0 Phase 6 — docs/34 "Testing." End-to-end orchestration tests, entirely fake-backed —
//  no real network, no real account, ever. `@Suite(.serialized)`: every test here reads/writes
//  `CloudStatisticsPreference`, real process-global App Group `UserDefaults` state — plain
//  `.serialized` is sufficient (unlike `SyncPreference`, no other suite currently touches this
//  key, so the cross-suite `.syncPreferenceSerialized` trait isn't needed here).
//

import Testing
import Foundation
@testable import Kue

@Suite(.serialized)
@MainActor
struct StatisticsCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCoordinator(transport: FakeStatisticsTransport = FakeStatisticsTransport(), store: FakeCloudStatisticsStateStore = FakeCloudStatisticsStateStore()) -> StatisticsCoordinator {
        StatisticsCoordinator(stateStore: store, transport: transport)
    }

    private func makeSignedInAccount(email: String = FakeAccountProvider.fixtureEmail) async -> AccountCoordinator {
        let provider = FakeAccountProvider()
        let account = AccountCoordinator(provider: provider, secureStore: FakeSecureStore())
        await account.signIn(email: email, password: FakeAccountProvider.fixturePassword)
        return account
    }

    private func makeSignedOutAccount() -> AccountCoordinator {
        AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
    }

    private func accessToken(of account: AccountCoordinator) -> String? {
        guard case .signedIn(let session, _) = account.state else { return nil }
        return session.accessToken
    }

    // MARK: Preference gating

    @Test func disabledPreferenceReportsLocalOnlyAndNeverTouchesTheTransport() async {
        CloudStatisticsPreference.setEnabled(false)
        let transport = FakeStatisticsTransport()
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport).refreshCloudUpload(events: [], account: account, now: now)
        #expect(status == .localOnly)
        #expect(transport.uploadCallCount == 0)
    }

    @Test func enabledButSignedOutReportsSignInRequired() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let status = await makeCoordinator(transport: transport).refreshCloudUpload(events: [], account: makeSignedOutAccount(), now: now)
        #expect(status == .signInRequired)
        #expect(transport.uploadCallCount == 0)
    }

    // MARK: Upload and debounce

    @Test func enabledAndSignedInUploadsAndReportsUpToDate() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport).refreshCloudUpload(events: [], account: account, now: now)
        guard case .upToDate = status else { Issue.record("expected .upToDate, got \(status)"); return }
        #expect(transport.uploadCallCount == 1)
    }

    @Test func repeatedRefreshWithUnchangedStatisticsSkipsTheNetworkCall() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let store = FakeCloudStatisticsStateStore()
        let coordinator = makeCoordinator(transport: transport, store: store)
        let account = await makeSignedInAccount()
        _ = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        _ = await coordinator.refreshCloudUpload(events: [], account: account, now: now.addingTimeInterval(60))
        // Same week, identical (empty) statistics both times — the second call must be a pure
        // debounce, never a second network round trip (requirement I: "debounce cloud
        // aggregate uploads where appropriate").
        #expect(transport.uploadCallCount == 1)
    }

    @Test func aGenuineChangeInStatisticsUploadsAgainRatherThanStayingDebounced() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let store = FakeCloudStatisticsStateStore()
        let coordinator = makeCoordinator(transport: transport, store: store)
        let account = await makeSignedInAccount()
        let event = KueEvent(title: "Interview", eventType: .interview, startDate: now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual, createdAt: now, updatedAt: now)
        _ = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        _ = await coordinator.refreshCloudUpload(events: [event], account: account, now: now)
        #expect(transport.uploadCallCount == 2)
    }

    // MARK: Account isolation (requirement E)

    @Test func accountSwitchNeverUploadsOneAccountsAggregatesUnderAnothersAndBothUploadIndependently() async throws {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let store = FakeCloudStatisticsStateStore()
        let coordinator = makeCoordinator(transport: transport, store: store)

        let accountA = await makeSignedInAccount(email: FakeAccountProvider.fixtureEmail)
        _ = await coordinator.refreshCloudUpload(events: [], account: accountA, now: now)
        let tokenA = try #require(accessToken(of: accountA))
        #expect(transport.storedPayloads(forToken: tokenA).count == 1)

        // A second, different account signs in on this same device.
        let providerB = FakeAccountProvider()
        _ = try? await providerB.signUp(email: "second@kue.test", password: "password123", username: "seconduser", displayName: nil)
        let accountB = AccountCoordinator(provider: providerB, secureStore: FakeSecureStore())
        if let confirmationPayload = providerB.directCallbackToken(for: "second@kue.test") {
            await accountB.handleAuthCallback(confirmationPayload)
        }
        await accountB.signIn(email: "second@kue.test", password: "password123")

        _ = await coordinator.refreshCloudUpload(events: [], account: accountB, now: now)
        let tokenB = try #require(accessToken(of: accountB))

        // Never the same token (a real second account) — Account B's own upload happened
        // (never blocked by Account A's "already uploaded this week" bookkeeping), and it is
        // stored only under Account B's own token, never disclosed to or merged with A's.
        #expect(tokenA != tokenB)
        #expect(transport.storedPayloads(forToken: tokenB).count == 1)
        #expect(transport.storedPayloads(forToken: tokenA).count == 1) // A's own row is untouched
    }

    // MARK: Error mapping / retry

    @Test func aNetworkFailureReportsOfflineAndLeavesTheDoorOpenForAutomaticRetry() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        transport.nextUploadError = .networkFailure
        let account = await makeSignedInAccount()
        let coordinator = makeCoordinator(transport: transport)
        let status = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        #expect(status == .offline)

        // The next call is a genuine retry, not silently skipped — nothing was recorded as
        // "already uploaded" after a failure.
        let retryStatus = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        guard case .upToDate = retryStatus else { Issue.record("expected .upToDate on retry, got \(retryStatus)"); return }
        #expect(transport.uploadCallCount == 2)
    }

    @Test func aNotAuthenticatedFailureReportsSignInRequired() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        transport.nextUploadError = .notAuthenticated
        let account = await makeSignedInAccount()
        let status = await makeCoordinator(transport: transport).refreshCloudUpload(events: [], account: account, now: now)
        #expect(status == .signInRequired)
    }

    // MARK: Deletion

    @Test func deleteCloudStatisticsCallsTheTransportAndResetsLocalBookkeeping() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let store = FakeCloudStatisticsStateStore()
        let coordinator = makeCoordinator(transport: transport, store: store)
        let account = await makeSignedInAccount()
        _ = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        #expect(transport.uploadCallCount == 1)

        let deleted = await coordinator.deleteCloudStatistics(account: account)
        #expect(deleted)
        #expect(transport.deleteCallCount == 1)
        #expect(coordinator.status == .localOnly)

        // Bookkeeping was cleared — an identical re-upload afterward is a genuine new upload,
        // never mistaken for "nothing changed since last time" (there is no "last time" anymore).
        _ = await coordinator.refreshCloudUpload(events: [], account: account, now: now)
        #expect(transport.uploadCallCount == 2)
    }

    @Test func deleteCloudStatisticsFailsHonestlyWhenSignedOut() async {
        let transport = FakeStatisticsTransport()
        let deleted = await makeCoordinator(transport: transport).deleteCloudStatistics(account: makeSignedOutAccount())
        #expect(!deleted)
        #expect(transport.deleteCallCount == 0)
    }

    // MARK: Disabling

    @Test func handlePreferenceDisabledImmediatelyReportsLocalOnly() async {
        let coordinator = makeCoordinator()
        coordinator.handlePreferenceDisabled()
        #expect(coordinator.status == .localOnly)
    }
}
