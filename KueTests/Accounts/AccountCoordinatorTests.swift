//
//  AccountCoordinatorTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Testing." `FakeAccountProvider`/`FakeSecureStore` only — never a
//  real Supabase project or the real Keychain. Covers: account state transitions, session
//  restoration, expired-session handling, refresh failure, offline behavior, sign-out cleanup,
//  duplicate-callback idempotency, secure-store behavior through the fake abstraction, no
//  secret leakage in error/log descriptions, and Personal-build (`provider == nil`)
//  unavailable behavior.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct AccountCoordinatorTests {
    private func makeCoordinator(seedFixtureAccount: Bool = true) -> (AccountCoordinator, FakeAccountProvider, FakeSecureStore) {
        let provider = FakeAccountProvider(seedFixtureAccount: seedFixtureAccount)
        let secureStore = FakeSecureStore()
        return (AccountCoordinator(provider: provider, secureStore: secureStore), provider, secureStore)
    }

    // MARK: - Unavailable (missing configuration — Personal-build behavior)

    @Test func aNilProviderProducesTheUnavailableStateImmediately() {
        let coordinator = AccountCoordinator(provider: nil, secureStore: FakeSecureStore())
        #expect(coordinator.state == .unavailable(.configurationMissing))
    }

    @Test func signUpIsANoOpWhenUnavailable() async {
        let coordinator = AccountCoordinator(provider: nil, secureStore: FakeSecureStore())
        await coordinator.signUp(email: "a@b.com", password: "password1", username: "newuser", displayName: nil)
        #expect(coordinator.state == .unavailable(.configurationMissing))
    }

    // MARK: - Registration / confirmation

    @Test func signUpTransitionsToAwaitingEmailConfirmation() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.signUp(email: "new@kue.test", password: "password1", username: "newperson", displayName: "New Person")
        #expect(coordinator.state == .awaitingEmailConfirmation(email: "new@kue.test"))
    }

    @Test func signUpWithATakenUsernameFailsAndStaysSignedOut() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.signUp(email: "new@kue.test", password: "password1", username: FakeAccountProvider.fixtureUsername, displayName: nil)
        #expect(coordinator.state == .signedOut)
        #expect(coordinator.lastError == .usernameTaken)
    }

    @Test func cancelPendingConfirmationReturnsToSignedOutWithNoAPICall() async {
        let (coordinator, provider, _) = makeCoordinator()
        await coordinator.signUp(email: "new@kue.test", password: "password1", username: "newperson", displayName: nil)
        coordinator.cancelPendingConfirmation()
        #expect(coordinator.state == .signedOut)
        #expect(provider.signInCallCount == 0)
    }

    // MARK: - Sign in / sign out

    @Test func signInWithValidCredentialsSignsIn() async {
        let (coordinator, _, secureStore) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        #expect(coordinator.state.session != nil)
        #expect(secureStore.storedSession != nil) // requirement E: session persisted securely
    }

    @Test func signInWithWrongPasswordFailsWithInvalidCredentials() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: "wrong-password")
        #expect(coordinator.state == .signedOut)
        #expect(coordinator.lastError == .invalidCredentials)
    }

    /// Requirement N: "prevent... repeated registration submissions" — a second concurrent
    /// call while one is already in flight is a no-op, not a second network call.
    /// `signInDelayNanoseconds` keeps the first call genuinely in flight long enough for the
    /// second, later call to reliably observe `isAuthenticating == true` — a bare `async let`
    /// race here would be flaky (Swift gives no ordering guarantee between two independently
    /// spawned tasks reaching their first suspension point).
    @Test func aSecondSignInCallWhileOneIsAlreadyAuthenticatingIsIgnored() async {
        let (coordinator, provider, _) = makeCoordinator()
        provider.signInDelayNanoseconds = 200_000_000 // 200ms — comfortably longer than the gap below
        let firstTask = Task { await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword) }
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms — enough for the first call to set .authenticating
        #expect(coordinator.isAuthenticating)
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        await firstTask.value
        #expect(provider.signInCallCount == 1)
    }

    @Test func signOutClearsStateAndSecureStoreEvenIfServerCallWouldFail() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        await coordinator.signOut()
        #expect(coordinator.state == .signedOut)
        #expect(secureStore.storedSession == nil)
        #expect(provider.deleteAccountCallCount == 0) // sanity: signOut never deletes anything
    }

    // MARK: - Session restoration

    @Test func restoreSessionWithNoStoredSessionStaysSignedOut() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.restoreSession()
        #expect(coordinator.state == .signedOut)
    }

    @Test func restoreSessionWithAFreshStoredSessionSignsInDirectly() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        let user = provider.accountsByEmail[FakeAccountProvider.fixtureEmail]!.user
        let freshSession = AccountSession(accessToken: "tok", refreshToken: "ref", expiresAt: .now.addingTimeInterval(3600), user: user)
        try? secureStore.saveSession(freshSession)

        await coordinator.restoreSession()
        #expect(coordinator.state.session?.accessToken == "tok")
    }

    @Test func restoreSessionWithAnExpiredStoredSessionRefreshesAutomatically() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        let user = provider.accountsByEmail[FakeAccountProvider.fixtureEmail]!.user
        let expiredSession = AccountSession(accessToken: "stale", refreshToken: "ref", expiresAt: .now.addingTimeInterval(-10), user: user)
        try? secureStore.saveSession(expiredSession)

        await coordinator.restoreSession()
        #expect(provider.refreshCallCount == 1)
        #expect(coordinator.state.session?.accessToken != "stale")
    }

    @Test func restoreSessionNeverBlocksOrCrashesOnACorruptSecureStore() async {
        let (coordinator, _, secureStore) = makeCoordinator()
        secureStore.errorToThrow = SecureStoreError.keychainFailed(-1)
        await coordinator.restoreSession() // must not throw/crash
        #expect(coordinator.state == .signedOut)
    }

    // MARK: - Refresh (expired-session handling, refresh failure, dedup)

    @Test func refreshFailureTransitionsToSessionExpiredAndClearsTheStore() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        let user = provider.accountsByEmail[FakeAccountProvider.fixtureEmail]!.user
        let expiredSession = AccountSession(accessToken: "stale", refreshToken: "bad-refresh", expiresAt: .now.addingTimeInterval(-10), user: user)
        try? secureStore.saveSession(expiredSession)
        provider.errorToThrowOnRefresh = .refreshFailed

        await coordinator.restoreSession()
        #expect(coordinator.state == .sessionExpired)
        #expect(secureStore.storedSession == nil)
    }

    @Test func refreshIfNeededReturnsTheSameSessionWhenNotExpired() async {
        let (coordinator, provider, _) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        let before = coordinator.state.session
        let result = await coordinator.refreshIfNeeded()
        #expect(result == before)
        #expect(provider.refreshCallCount == 0) // never refreshes an already-valid session
    }

    /// Requirement N: "multiple simultaneous refreshes" / "refresh-token races" — two
    /// concurrent *entry points* into a refresh (not just two calls to the same function)
    /// share one underlying `provider.refreshSession` call. This is the exact real bug this
    /// phase's own test-writing found and `AccountCoordinator.performRefresh` was fixed for:
    /// `restoreSession()`'s own expired-session branch didn't originally check for an
    /// already-in-flight refresh before starting a second one.
    @Test func concurrentRestoreSessionCallsShareOneInFlightRefresh() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        let user = provider.accountsByEmail[FakeAccountProvider.fixtureEmail]!.user
        let expiredSession = AccountSession(accessToken: "stale", refreshToken: "ref", expiresAt: .now.addingTimeInterval(-10), user: user)
        try? secureStore.saveSession(expiredSession)

        // Two calls issued back to back, before either has had a chance to complete —
        // `restoreSession`'s own `guard case .signedOut = state` still passes for the second
        // call at the moment it starts, since `state` isn't updated until the refresh resolves.
        async let a: () = coordinator.restoreSession()
        async let b: () = coordinator.restoreSession()
        _ = await (a, b)

        #expect(provider.refreshCallCount == 1)
        #expect(coordinator.state.session?.accessToken != "stale")
    }


    // MARK: - Session-refresh integration (profile load/edit, password update, deletion)
    //
    // Every one of these uses `seedSignedInStateForTesting`/`seedPasswordRecoveryStateForTesting`
    // (`#if DEBUG`-only, `AccountCoordinator`'s own file) to place an already-expired session
    // directly into `state` — the one precondition the coordinator's public API can never
    // produce on its own: every real state-setting path either uses a freshly-obtained session
    // or refreshes first, and `AccountSession.isExpired(now:)`'s own 30-second buffer means a
    // deliberately-short-lived *fake* session (the only kind a `Task.sleep`-based test could
    // construct without the seam) is already "expired" the instant it's minted — including
    // during that same call's own internal `loadProfile()`, making a real signIn/callback-based
    // construction refresh immediately and impossible to isolate from the operation under test.

    private func expiredSession(for provider: FakeAccountProvider, accessToken: String = "stale-access-token") -> AccountSession {
        let user = provider.accountsByEmail[FakeAccountProvider.fixtureEmail]!.user
        return AccountSession(accessToken: accessToken, refreshToken: "stale-refresh", expiresAt: .now.addingTimeInterval(-10), user: user)
    }

    @Test func loadProfileRefreshesAnExpiredSessionBeforeFetching() async {
        let (coordinator, provider, _) = makeCoordinator()
        coordinator.seedSignedInStateForTesting(session: expiredSession(for: provider))

        await coordinator.loadProfile()
        #expect(provider.refreshCallCount == 1)
        #expect(provider.lastFetchProfileAccessToken != "stale-access-token")
        #expect(provider.lastFetchProfileAccessToken == coordinator.state.session?.accessToken)
    }

    @Test func updateProfileRefreshesAnExpiredSessionBeforeUpdating() async {
        let (coordinator, provider, _) = makeCoordinator()
        coordinator.seedSignedInStateForTesting(session: expiredSession(for: provider))

        let succeeded = await coordinator.updateProfile(username: nil, displayName: "New Name")
        #expect(succeeded)
        #expect(provider.refreshCallCount == 1)
        #expect(provider.lastUpdateProfileAccessToken != "stale-access-token")
        #expect(provider.lastUpdateProfileAccessToken == coordinator.state.session?.accessToken)
    }

    @Test func setNewPasswordRefreshesAnExpiredRecoverySessionBeforeUpdating() async {
        let (coordinator, provider, _) = makeCoordinator()
        coordinator.seedPasswordRecoveryStateForTesting(session: expiredSession(for: provider))

        await coordinator.setNewPassword("brand-new-password")
        #expect(provider.refreshCallCount == 1)
        #expect(provider.lastUpdatePasswordAccessToken != "stale-access-token")
        #expect(provider.lastUpdatePasswordAccessToken == coordinator.state.session?.accessToken)
        if case .signedIn = coordinator.state {} else { Issue.record("expected .signedIn after setting a new password") }
    }

    @Test func deleteAccountRefreshesAnExpiredSessionBeforeDeleting() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        coordinator.seedSignedInStateForTesting(session: expiredSession(for: provider))

        let succeeded = await coordinator.deleteAccount()
        #expect(succeeded)
        #expect(provider.refreshCallCount == 1)
        #expect(provider.lastDeleteAccountAccessToken != "stale-access-token")
        #expect(coordinator.state == .signedOut)
        #expect(secureStore.storedSession == nil)
    }

    /// The failure half of the same guarantee — requirement: "truthfully enter `.sessionExpired`
    /// if refresh fails," proven from an authenticated-operation entry point, not just from
    /// `restoreSession()` (already covered by `refreshFailureTransitionsToSessionExpiredAndClearsTheStore`).
    @Test func updateProfileEntersSessionExpiredWhenTheRefreshItselfFails() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        coordinator.seedSignedInStateForTesting(session: expiredSession(for: provider))
        provider.errorToThrowOnRefresh = .refreshFailed

        let succeeded = await coordinator.updateProfile(username: nil, displayName: "New Name")
        #expect(!succeeded)
        #expect(coordinator.state == .sessionExpired)
        #expect(secureStore.storedSession == nil)
        #expect(provider.lastUpdateProfileAccessToken == nil) // never even attempted with a stale token
    }

    // MARK: - Offline behavior

    @Test func offlineSignInSurfacesTheOfflineError() async {
        let (coordinator, provider, _) = makeCoordinator()
        provider.errorToThrowOnSignIn = .offline
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        #expect(coordinator.lastError == .offline)
        #expect(coordinator.state == .signedOut) // never fabricates a session
    }

    // MARK: - Auth callback idempotency

    @Test func handlingTheSameCallbackTwiceOnlyExchangesOnce() async {
        let (coordinator, provider, _) = makeCoordinator()
        await coordinator.signUp(email: "confirmme@kue.test", password: "password1", username: "confirmme", displayName: nil)
        let payload = provider.directCallbackToken(for: "confirmme@kue.test")!

        await coordinator.handleAuthCallback(payload)
        #expect(coordinator.state.session != nil)
        let sessionAfterFirst = coordinator.state.session

        await coordinator.handleAuthCallback(payload) // identical payload again
        #expect(coordinator.state.session == sessionAfterFirst) // unchanged, not re-exchanged
    }

    /// The real bug this pass fixed: `lastHandledCallback` used to be set *before* the exchange
    /// even ran, so a transient offline/server failure permanently marked the link "handled,"
    /// silently swallowing every future retry of the identical URL. Now it's set only after a
    /// successful exchange *and* a successful secure-store write — a failed attempt must leave
    /// the door open for the exact same payload to succeed on retry.
    @Test func handleAuthCallbackFailureAllowsRetryWithTheIdenticalPayload() async {
        let (coordinator, provider, _) = makeCoordinator()
        let payload = provider.directCallbackToken(for: FakeAccountProvider.fixtureEmail, kind: .recovery)!
        provider.errorToThrowOnExchangeCallback = .offline

        await coordinator.handleAuthCallback(payload)
        #expect(coordinator.lastError == .offline)
        if case .passwordRecovery = coordinator.state { Issue.record("must not transition on a failed exchange") }
        #expect(provider.exchangeCallbackCallCount == 1)

        provider.errorToThrowOnExchangeCallback = nil
        await coordinator.handleAuthCallback(payload) // identical payload, retried after the transient failure
        #expect(provider.exchangeCallbackCallCount == 2) // both attempts actually reached the network
        if case .passwordRecovery = coordinator.state {} else { Issue.record("expected .passwordRecovery after the retry succeeded") }
    }

    /// A `SecureStoring` failure must be treated exactly like an exchange failure — the session
    /// came back from the server, but never actually got stored, so the callback is not "handled"
    /// either.
    @Test func handleAuthCallbackSecureStoreFailureAlsoAllowsRetry() async {
        let (coordinator, provider, secureStore) = makeCoordinator()
        let payload = provider.directCallbackToken(for: FakeAccountProvider.fixtureEmail, kind: .recovery)!
        secureStore.errorToThrow = SecureStoreError.keychainFailed(-1)

        await coordinator.handleAuthCallback(payload)
        if case .passwordRecovery = coordinator.state { Issue.record("must not transition when the secure store write failed") }
        #expect(provider.exchangeCallbackCallCount == 1)

        secureStore.errorToThrow = nil
        await coordinator.handleAuthCallback(payload)
        #expect(provider.exchangeCallbackCallCount == 2)
        if case .passwordRecovery = coordinator.state {} else { Issue.record("expected .passwordRecovery after the retry succeeded") }
    }

    /// Requirement M/N: two truly concurrent deliveries of the identical payload (the real,
    /// documented `onOpenURL`-fires-twice case) must still only exchange once — mirrors
    /// `concurrentRestoreSessionCallsShareOneInFlightRefresh`'s own proof shape for
    /// `inFlightRefresh` above, applied to `inFlightCallback`.
    @Test func concurrentHandleAuthCallbackCallsShareOneInFlightExchange() async {
        let (coordinator, provider, _) = makeCoordinator()
        let payload = provider.directCallbackToken(for: FakeAccountProvider.fixtureEmail, kind: .recovery)!

        async let a: () = coordinator.handleAuthCallback(payload)
        async let b: () = coordinator.handleAuthCallback(payload)
        _ = await (a, b)

        #expect(provider.exchangeCallbackCallCount == 1)
        if case .passwordRecovery = coordinator.state {} else { Issue.record("expected .passwordRecovery") }
    }

    @Test func aRecoveryCallbackTransitionsToPasswordRecoveryNotSignedIn() async {
        let (coordinator, provider, _) = makeCoordinator()
        let payload = provider.directCallbackToken(for: FakeAccountProvider.fixtureEmail, kind: .recovery)!
        await coordinator.handleAuthCallback(payload)
        if case .passwordRecovery = coordinator.state {
            // expected
        } else {
            Issue.record("expected .passwordRecovery, got \(coordinator.state)")
        }
    }

    @Test func setNewPasswordAfterRecoveryTransitionsToSignedIn() async {
        let (coordinator, provider, _) = makeCoordinator()
        let payload = provider.directCallbackToken(for: FakeAccountProvider.fixtureEmail, kind: .recovery)!
        await coordinator.handleAuthCallback(payload)
        await coordinator.setNewPassword("brand-new-password")
        #expect(coordinator.state.session != nil)
        if case .signedIn = coordinator.state {} else { Issue.record("expected .signedIn") }
    }

    // MARK: - Deletion

    @Test func deleteAccountSignsOutLocallyOnSuccess() async {
        let (coordinator, _, secureStore) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        let succeeded = await coordinator.deleteAccount()
        #expect(succeeded)
        #expect(coordinator.state == .signedOut)
        #expect(secureStore.storedSession == nil)
    }

    @Test func deleteAccountFailureNeverSignsOutLocally() async {
        let (coordinator, provider, _) = makeCoordinator()
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        provider.errorToThrowOnDelete = .serverError
        let succeeded = await coordinator.deleteAccount()
        #expect(!succeeded)
        #expect(coordinator.state.session != nil) // still signed in — never fakes a deletion
    }

    // MARK: - No secret leakage in descriptions

    @Test func aSessionsDescriptionNeverContainsItsOwnTokens() {
        let session = AccountSession(accessToken: "super-secret-access", refreshToken: "super-secret-refresh", expiresAt: .now, user: AccountUser(id: UUID(), email: "a@b.com", emailConfirmedAt: nil, createdAt: .now))
        #expect(!"\(session)".contains("super-secret-access"))
        #expect(!"\(session)".contains("super-secret-refresh"))
    }

    @Test func aCallbackPayloadsDescriptionNeverContainsItsToken() {
        let direct = AccountAuthCallbackPayload(kind: .recovery, token: .direct(accessToken: "secret-access", refreshToken: "secret-refresh", expiresIn: 3600))
        #expect(!"\(direct)".contains("secret-access"))
        #expect(!"\(direct)".contains("secret-refresh"))

        let hash = AccountAuthCallbackPayload(kind: .recovery, token: .hash("secret-hash-value"))
        #expect(!"\(hash)".contains("secret-hash-value"))
    }
}
