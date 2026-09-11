//
//  AccountCoordinator.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Architecture." The one `@Observable`, `@MainActor` account/
//  session coordinator every iPhone and Mac view reads from — requirement D. Constructed once
//  at app launch (`KueApp`/`KueMacApp`, mirroring `VoiceInputCoordinator`'s own `@Observable`
//  shape but injected app-wide via `.environment(_:)` rather than view-owned `@State`, since
//  account state needs to be visible from Settings/Profile *and* survive navigating away and
//  back) and injected down; every mutation goes through here, never directly through
//  `AccountProviding`/`SecureStoring` from a view.
//
//  Never blocks app launch (requirement N) — `restoreSession()` is `async` and called from
//  `.task` at the root view, not from `init()`'s synchronous path, the same "defer real I/O
//  out of the App's synchronous init" precedent `KueApp.init()`'s own
//  `NotificationActionHandler.registerCategories()` deferral already establishes.
//

import Foundation

@MainActor
@Observable
final class AccountCoordinator {
    private(set) var state: AccountState

    private let provider: AccountProviding?
    private let secureStore: SecureStoring
    private let configurationAvailable: Bool

    /// Requirement N: "prevent... multiple simultaneous refreshes" / "refresh-token races" —
    /// a second concurrent caller awaits the *same* in-flight refresh rather than starting its
    /// own, and this is cleared the moment it finishes so a later, genuinely new refresh isn't
    /// blocked by a stale reference.
    private var inFlightRefresh: Task<AccountSession, Error>?
    /// The exact last *successfully* processed callback — requirement M: "duplicate callback
    /// idempotency." Re-delivering the identical payload (the OS calling `onOpenURL` twice for
    /// one tap is a real, documented iOS behavior) is a safe no-op rather than a second network
    /// exchange. Set only once `performCallbackExchange` has both exchanged the token *and*
    /// persisted the resulting session — never on entry — so a transient offline/server failure
    /// never permanently swallows a link the user could otherwise retry by tapping it again.
    private var lastHandledCallback: AccountAuthCallbackPayload?
    /// A callback exchange currently in flight, distinct from `lastHandledCallback` above — a
    /// second, *concurrent* delivery of the identical payload (the same real `onOpenURL`-fires-
    /// twice case) awaits this attempt's own result instead of starting a second network
    /// exchange, regardless of whether that attempt ultimately succeeds or fails.
    private var inFlightCallback: (payload: AccountAuthCallbackPayload, task: Task<Void, Never>)?

    init(provider: AccountProviding?, secureStore: SecureStoring) {
        self.provider = provider
        self.secureStore = secureStore
        self.configurationAvailable = provider != nil
        self.state = provider == nil ? .unavailable(.configurationMissing) : .signedOut
    }

    // MARK: - Launch-time restoration (never blocks launch — see this file's own header)

    /// Idempotent — calling it more than once (e.g. a second `.task` fire after a scene
    /// reconnection) never starts a second concurrent restoration once one has already set a
    /// non-`.signedOut` state, and never regresses an already-signed-in state back to
    /// `.signedOut`.
    func restoreSession() async {
        guard configurationAvailable else { return }
        guard case .signedOut = state else { return }
        guard let stored = try? secureStore.loadSession() else { return }

        if stored.isExpired() {
            await performRefresh(stored)
        } else {
            state = .signedIn(session: stored, profile: nil)
            await loadProfile()
        }
    }

    // MARK: - Registration / sign-in / sign-out

    func signUp(email: String, password: String, username: String, displayName: String?) async {
        guard let provider else { return }
        guard !isAuthenticating else { return } // requirement N: no duplicate submissions
        state = .authenticating
        do {
            let user = try await provider.signUp(email: email, password: password, username: username, displayName: displayName)
            state = .awaitingEmailConfirmation(email: user.email)
        } catch {
            state = .signedOut
            lastError = Self.asAccountError(error)
        }
    }

    func signIn(email: String, password: String) async {
        guard let provider else { return }
        guard !isAuthenticating else { return }
        state = .authenticating
        do {
            let session = try await provider.signIn(email: email, password: password)
            try? secureStore.saveSession(session)
            state = .signedIn(session: session, profile: nil)
            await loadProfile()
        } catch AccountError.emailNotConfirmed {
            state = .awaitingEmailConfirmation(email: email)
            lastError = .emailNotConfirmed
        } catch {
            state = .signedOut
            lastError = Self.asAccountError(error)
        }
    }

    /// Requirement N: "stale account UI after sign-out" — `state` is set to `.signedOut`
    /// *before* the (best-effort, fire-and-forget-tolerant) network revocation, so the UI
    /// never shows a signed-in screen a beat longer than it should.
    func signOut() async {
        let session = state.session
        try? secureStore.clearSession()
        state = .signedOut
        lastError = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        if let provider, let session {
            try? await provider.signOut(session: session)
        }
    }

    func requestPasswordReset(email: String) async {
        guard let provider else { return }
        do {
            try await provider.requestPasswordReset(email: email)
            lastError = nil
        } catch {
            lastError = Self.asAccountError(error)
        }
    }

    /// Returns from `.awaitingEmailConfirmation` to `.signedOut` — no session exists yet at
    /// that point, so there's nothing to revoke server-side; this is a pure local UI-state
    /// reset ("try a different email").
    func cancelPendingConfirmation() {
        guard case .awaitingEmailConfirmation = state else { return }
        state = .signedOut
        lastError = nil
    }

    func resendConfirmationEmail() async {
        guard let provider, case .awaitingEmailConfirmation(let email) = state else { return }
        do {
            try await provider.resendConfirmationEmail(email: email)
            lastError = nil
        } catch {
            lastError = Self.asAccountError(error)
        }
    }

    func setNewPassword(_ newPassword: String) async {
        guard let provider, case .passwordRecovery = state else { return }
        // Refresh first — a password-recovery session that's sat unused long enough to expire
        // must be rotated before this authenticated call, not sent with a stale access token.
        // `refreshIfNeeded()` reads `state.session`, which resolves to this exact recovery
        // session (`AccountState.session`'s own `.passwordRecovery` case) — see this file's own
        // "Refresh" section below for the shared, deduplicated implementation every
        // authenticated operation now goes through.
        guard let session = await refreshIfNeeded() else { return } // .sessionExpired set inside
        do {
            try await provider.updatePassword(newPassword, session: session)
            try? secureStore.saveSession(session)
            state = .signedIn(session: session, profile: nil)
            await loadProfile()
        } catch {
            lastError = Self.asAccountError(error)
        }
    }

    // MARK: - Auth callback (deep link)

    /// Idempotent (requirement M/J) — the exact same payload delivered twice in a row, once it
    /// has already *succeeded* once, is a no-op the second time; a genuinely different payload
    /// (a new tap) is always processed. A payload that previously *failed* (offline, a
    /// transient server error, or a `SecureStoring` failure) is deliberately **not** remembered
    /// as handled — the identical link must still work if the user taps it again. Two truly
    /// concurrent deliveries of the same payload (a real, documented duplicate `onOpenURL` fire)
    /// share the one in-flight attempt rather than each starting their own network exchange.
    func handleAuthCallback(_ payload: AccountAuthCallbackPayload) async {
        guard let provider else { return }
        guard payload != lastHandledCallback else { return } // already succeeded — no-op
        if let inFlight = inFlightCallback, inFlight.payload == payload {
            await inFlight.task.value
            return
        }
        let task = Task { await self.performCallbackExchange(payload, provider: provider) }
        inFlightCallback = (payload, task)
        await task.value
        inFlightCallback = nil
    }

    /// The one place a callback is ever actually exchanged — see `handleAuthCallback`'s own
    /// header for why marking `lastHandledCallback` lives here, only on the success path.
    private func performCallbackExchange(_ payload: AccountAuthCallbackPayload, provider: AccountProviding) async {
        do {
            let session = try await provider.exchangeCallback(payload)
            // Not `try?` — a `SecureStoring` failure must be treated exactly like an exchange
            // failure (requirement: "mark a callback as handled only after successful exchange
            // *and* secure storage"), so this session is never silently lost and the same link
            // stays retryable.
            try secureStore.saveSession(session)
            lastHandledCallback = payload
            switch payload.kind {
            case .recovery:
                state = .passwordRecovery(session: session)
            case .signup, .magiclink, .invite, .emailChange:
                state = .signedIn(session: session, profile: nil)
                await loadProfile()
            }
        } catch {
            lastError = Self.asAccountError(error)
        }
    }

    // MARK: - Profile

    private(set) var isLoadingProfile = false

    /// No longer takes an explicit `session` — every call site already set `state` to reflect
    /// the session it wants loaded, and reading it back out here would just be re-deriving what
    /// `refreshIfNeeded()` below already reads from `state` itself. Refreshing first means a
    /// profile fetch triggered against a `state` whose session has since expired (e.g. this app
    /// was backgrounded for a long stretch, then a caller asks to reload the profile) rotates
    /// the token before the request, rather than sending a stale one and surfacing whatever
    /// error the server happens to return for it.
    func loadProfile() async {
        guard let provider else { return }
        guard !isLoadingProfile else { return } // requirement N: "repeated profile fetch loops"
        guard let session = await refreshIfNeeded() else { return } // .sessionExpired set inside
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        do {
            let profile = try await provider.fetchProfile(userID: session.user.id, session: session)
            if case .signedIn = state { state = .signedIn(session: session, profile: profile) }
        } catch {
            // A profile fetch failure never signs the user out or hides local data —
            // requirement D: "never delete, hide, or lock local events because authentication
            // fails," and a profile is a smaller version of that same principle.
            lastError = Self.asAccountError(error)
        }
    }

    /// Same refresh-first shape as `loadProfile()` above — editing a profile is exactly as
    /// authenticated an operation as reading one, and must never send a stale access token.
    func updateProfile(username: String?, displayName: String?) async -> Bool {
        guard let provider else { return false }
        guard let session = await refreshIfNeeded() else { return false } // .sessionExpired set inside
        do {
            let profile = try await provider.updateProfile(userID: session.user.id, username: username, displayName: displayName, session: session)
            if case .signedIn = state { state = .signedIn(session: session, profile: profile) }
            lastError = nil
            return true
        } catch {
            lastError = Self.asAccountError(error)
            return false
        }
    }

    func checkUsernameAvailability(_ username: String) async -> Bool? {
        guard let provider else { return nil }
        return try? await provider.isUsernameAvailable(username)
    }

    // MARK: - Deletion

    /// Same refresh-first shape as `loadProfile()`/`updateProfile(...)` above — a stale access
    /// token must never be the reason a genuinely authenticated deletion request fails.
    func deleteAccount() async -> Bool {
        guard let provider else { return false }
        guard let session = await refreshIfNeeded() else { return false } // .sessionExpired set inside
        do {
            try await provider.deleteAccount(session: session)
            try? secureStore.clearSession()
            state = .signedOut
            lastError = nil
            return true
        } catch {
            lastError = Self.asAccountError(error)
            return false
        }
    }

    // MARK: - Refresh (deduplicated — requirement N)

    /// Called before any authenticated request a view is about to make on the user's behalf.
    /// A second concurrent caller reuses the one in-flight `Task` rather than racing a second
    /// refresh against the same refresh token (which a real Supabase project would reject —
    /// refresh tokens are single-use and rotate).
    @discardableResult
    func refreshIfNeeded() async -> AccountSession? {
        guard let session = state.session else { return nil }
        guard session.isExpired() else { return session }
        return await performRefresh(session)
    }

    /// The one place a refresh is ever actually started — both `refreshIfNeeded()` above and
    /// `restoreSession()`'s own expired-session branch call this directly, so the in-flight
    /// dedup check lives here exactly once rather than being duplicated (and, as originally
    /// written here, *not* duplicated into `restoreSession`'s own call site — a real bug this
    /// phase's own test-writing caught: two concurrent entry points into a refresh could each
    /// start their own `Task` and overwrite `inFlightRefresh`, racing two refreshes against the
    /// same single-use, rotating refresh token).
    @discardableResult
    private func performRefresh(_ session: AccountSession) async -> AccountSession? {
        if let inFlightRefresh {
            return try? await inFlightRefresh.value
        }
        guard let provider else { return nil }
        let task = Task { try await provider.refreshSession(session) }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        do {
            let refreshed = try await task.value
            try? secureStore.saveSession(refreshed)
            switch state {
            case .signedIn(_, let profile): state = .signedIn(session: refreshed, profile: profile)
            default: state = .signedIn(session: refreshed, profile: nil)
            }
            return refreshed
        } catch {
            try? secureStore.clearSession()
            state = .sessionExpired
            return nil
        }
    }

    // MARK: - Error surface

    /// The last error a mutating call produced — a view reads this to show a banner, then
    /// typically clears it (`clearError()`) once shown, matching "accessible error
    /// announcements" without the coordinator needing a queue of them.
    private(set) var lastError: AccountError?
    func clearError() { lastError = nil }

    var isAuthenticating: Bool { if case .authenticating = state { return true }; return false }

    /// Maps any thrown error to a typed `AccountError` — a provider should only ever throw
    /// `AccountError` itself, but this is the one defensive boundary in case a future
    /// conformer (or a test double) throws something else.
    private static func asAccountError(_ error: Error) -> AccountError {
        (error as? AccountError) ?? .unknown("Something went wrong.")
    }

    #if DEBUG
    // MARK: - Test-only seam (session-refresh hardening pass)
    //
    // `AccountCoordinator`'s own public API can never place `state` into "signed in, but the
    // session is already expired" — every real path either uses a freshly-obtained session or
    // refreshes first, and `AccountSession.isExpired(now:)`'s own 30-second buffer means a
    // short-lived fake session is already "expired" from the instant it's minted, so even a
    // real, deliberately-short-lived fake session created through `signIn`/`handleAuthCallback`
    // gets refreshed *immediately* by that same call's own internal `loadProfile()` — there is
    // no way to reach "expired, but not yet refreshed" through the public surface, and a
    // wall-clock `Task.sleep` can't help either (it would need to sleep past that 30-second
    // buffer for real, which is both slow and still doesn't isolate one call's own refresh from
    // an earlier call's). These two setters exist only so `AccountCoordinatorTests`' session-
    // refresh-integration tests can construct that exact precondition directly and deterministically.
    func seedSignedInStateForTesting(session: AccountSession, profile: AccountProfile? = nil) {
        state = .signedIn(session: session, profile: profile)
    }

    func seedPasswordRecoveryStateForTesting(session: AccountSession) {
        state = .passwordRecovery(session: session)
    }
    #endif
}
