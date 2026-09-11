//
//  FakeAccountProvider.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Testing." A deterministic, in-memory `AccountProviding` — no
//  networking, no real Supabase project touched, ever. Same shape `FakeCalendarProvider`/
//  `FakeOCRTextRecognizer` already establish: configurable canned results/errors, a small
//  fixed in-memory "database" (`registeredAccounts`), and a `uiTestLaunchArgument` +
//  `makeFromLaunchArguments()` pair so `KueUITests` can install one exactly the way every
//  other Fake* service already is. Requirement M: "Use fake account providers only — never
//  real Supabase credentials."
//

import Foundation

final class FakeAccountProvider: AccountProviding {
    /// One fixed fixture account, confirmed and ready to sign in — mirrors
    /// `FakeCalendarProvider.makeUITestFixture()`'s own "one deterministic fixture" shape.
    static let fixtureEmail = "fixture@kue.test"
    static let fixturePassword = "fixture-password-123"
    static let fixtureUsername = "fixtureuser"
    static let fixtureUserID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    struct StoredAccount {
        var user: AccountUser
        var password: String
        var profile: AccountProfile
        var isConfirmed: Bool
    }

    private(set) var accountsByEmail: [String: StoredAccount] = [:]
    private var usernames: Set<String> = []

    /// When set, the next matching call throws this instead of doing its normal thing — lets
    /// a test simulate offline/server-error/rate-limited conditions deterministically.
    var errorToThrowOnSignIn: AccountError?
    var errorToThrowOnSignUp: AccountError?
    var errorToThrowOnRefresh: AccountError?
    var errorToThrowOnFetchProfile: AccountError?
    var errorToThrowOnUpdateProfile: AccountError?
    var errorToThrowOnDelete: AccountError?
    var errorToThrowOnPasswordReset: AccountError?
    /// Kue 3.0 Phase 4 (session-refresh hardening pass) — lets a test simulate a transient
    /// offline/server failure on the *first* callback exchange attempt, then clear it before
    /// retrying with the identical payload, proving `AccountCoordinator.handleAuthCallback`
    /// truthfully allows a retry after failure rather than permanently marking the link handled.
    var errorToThrowOnExchangeCallback: AccountError?

    /// Lets a test force `signIn` to stay in flight long enough to reliably observe
    /// `AccountCoordinator`'s own "reject a second concurrent call" guard — mirrors
    /// `FakeVoiceAudioSessionManager.simulateInterruptionAfterNanoseconds`'s own "small,
    /// explicit delay hook for a real race condition test" shape. `0` (the default) never
    /// delays anything — every other test's timing is unaffected.
    var signInDelayNanoseconds: UInt64 = 0

    /// Counts — requirement N: "prevent... repeated registration submissions" etc. are proven
    /// by asserting these stay at the expected count, not just that the call "worked."
    private(set) var signInCallCount = 0
    private(set) var signUpCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var deleteAccountCallCount = 0
    private(set) var exchangeCallbackCallCount = 0

    /// Kue 3.0 Phase 4 (session-refresh hardening pass) — the exact `accessToken` each
    /// authenticated call actually received, so a test can assert an operation issued after
    /// expiry used the *refreshed* token, not the stale one it was originally holding.
    private(set) var lastFetchProfileAccessToken: String?
    private(set) var lastUpdateProfileAccessToken: String?
    private(set) var lastUpdatePasswordAccessToken: String?
    private(set) var lastDeleteAccountAccessToken: String?

    init(seedFixtureAccount: Bool = true) {
        if seedFixtureAccount {
            let user = AccountUser(id: Self.fixtureUserID, email: Self.fixtureEmail, emailConfirmedAt: .now, createdAt: .now.addingTimeInterval(-86_400))
            let profile = AccountProfile(id: Self.fixtureUserID, username: Self.fixtureUsername, displayName: "Fixture User", avatarURL: nil, createdAt: user.createdAt, updatedAt: user.createdAt)
            accountsByEmail[Self.fixtureEmail] = StoredAccount(user: user, password: Self.fixturePassword, profile: profile, isConfirmed: true)
            usernames.insert(Self.fixtureUsername)
        }
    }

    func signUp(email: String, password: String, username: String, displayName: String?) async throws -> AccountUser {
        signUpCallCount += 1
        if let errorToThrowOnSignUp { throw errorToThrowOnSignUp }
        guard AccountValidation.isValidEmail(email) else { throw AccountError.invalidEmail }
        guard AccountValidation.isValidPassword(password) else { throw AccountError.weakPassword }
        if let reason = UsernamePolicy.validationError(for: username) { throw AccountError.usernameInvalid(reason) }
        guard accountsByEmail[email] == nil else { throw AccountError.emailAlreadyRegistered }
        let normalized = UsernamePolicy.normalize(username)
        guard !usernames.contains(normalized) else { throw AccountError.usernameTaken }

        let id = UUID()
        let now = Date.now
        let user = AccountUser(id: id, email: email, emailConfirmedAt: nil, createdAt: now)
        let profile = AccountProfile(id: id, username: normalized, displayName: displayName, avatarURL: nil, createdAt: now, updatedAt: now)
        accountsByEmail[email] = StoredAccount(user: user, password: password, profile: profile, isConfirmed: false)
        usernames.insert(normalized)
        return user
    }

    func signIn(email: String, password: String) async throws -> AccountSession {
        signInCallCount += 1
        if signInDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: signInDelayNanoseconds) }
        if let errorToThrowOnSignIn { throw errorToThrowOnSignIn }
        guard let stored = accountsByEmail[email], stored.password == password else { throw AccountError.invalidCredentials }
        guard stored.isConfirmed else { throw AccountError.emailNotConfirmed }
        return makeSession(for: stored.user)
    }

    func signOut(session: AccountSession) async throws {}

    func requestPasswordReset(email: String) async throws {
        if let errorToThrowOnPasswordReset { throw errorToThrowOnPasswordReset }
    }

    func resendConfirmationEmail(email: String) async throws {}

    func updatePassword(_ newPassword: String, session: AccountSession) async throws {
        lastUpdatePasswordAccessToken = session.accessToken
        guard var stored = accountsByEmail[session.user.email] else { throw AccountError.sessionExpired }
        stored.password = newPassword
        accountsByEmail[session.user.email] = stored
    }

    func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        refreshCallCount += 1
        if let errorToThrowOnRefresh { throw errorToThrowOnRefresh }
        guard let stored = accountsByEmail.values.first(where: { $0.user.id == session.user.id }) else { throw AccountError.refreshFailed }
        return makeSession(for: stored.user)
    }

    func fetchCurrentUser(session: AccountSession) async throws -> AccountUser {
        guard let stored = accountsByEmail.values.first(where: { $0.user.id == session.user.id }) else { throw AccountError.sessionExpired }
        return stored.user
    }

    func fetchProfile(userID: UUID, session: AccountSession) async throws -> AccountProfile? {
        lastFetchProfileAccessToken = session.accessToken
        if let errorToThrowOnFetchProfile { throw errorToThrowOnFetchProfile }
        return accountsByEmail.values.first(where: { $0.user.id == userID })?.profile
    }

    func updateProfile(userID: UUID, username: String?, displayName: String?, session: AccountSession) async throws -> AccountProfile {
        lastUpdateProfileAccessToken = session.accessToken
        if let errorToThrowOnUpdateProfile { throw errorToThrowOnUpdateProfile }
        guard let email = accountsByEmail.first(where: { $0.value.user.id == userID })?.key, var stored = accountsByEmail[email] else {
            throw AccountError.sessionExpired
        }
        if let username {
            if let reason = UsernamePolicy.validationError(for: username) { throw AccountError.usernameInvalid(reason) }
            let normalized = UsernamePolicy.normalize(username)
            if normalized != stored.profile.username {
                guard !usernames.contains(normalized) else { throw AccountError.usernameTaken }
                usernames.remove(stored.profile.username)
                usernames.insert(normalized)
                stored.profile.username = normalized
            }
        }
        if let displayName { stored.profile.displayName = displayName }
        stored.profile.updatedAt = .now
        accountsByEmail[email] = stored
        return stored.profile
    }

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        !usernames.contains(UsernamePolicy.normalize(username))
    }

    func exchangeCallback(_ payload: AccountAuthCallbackPayload) async throws -> AccountSession {
        exchangeCallbackCallCount += 1
        if let errorToThrowOnExchangeCallback { throw errorToThrowOnExchangeCallback }
        switch payload.token {
        case .direct(let accessToken, _, _):
            guard let stored = accountsByEmail.values.first(where: { "fake-access-\($0.user.id)" == accessToken }) else {
                throw AccountError.unknown("Unrecognized fixture callback token.")
            }
            var mutable = stored
            mutable.isConfirmed = true
            accountsByEmail[stored.user.email] = mutable
            return makeSession(for: mutable.user)
        case .hash(let hash):
            guard let stored = accountsByEmail.values.first(where: { "fake-hash-\($0.user.id)" == hash }) else {
                throw AccountError.unknown("Unrecognized fixture callback token.")
            }
            var mutable = stored
            mutable.isConfirmed = true
            accountsByEmail[stored.user.email] = mutable
            return makeSession(for: mutable.user)
        }
    }

    func deleteAccount(session: AccountSession) async throws {
        deleteAccountCallCount += 1
        lastDeleteAccountAccessToken = session.accessToken
        if let errorToThrowOnDelete { throw errorToThrowOnDelete }
        guard let email = accountsByEmail.first(where: { $0.value.user.id == session.user.id })?.key else { throw AccountError.sessionExpired }
        if let username = accountsByEmail[email]?.profile.username { usernames.remove(username) }
        accountsByEmail.removeValue(forKey: email)
    }

    // MARK: - Test helpers

    /// Lets a test drive the "tap the confirmation/recovery email link" step without a real
    /// email — the fixed, deterministic token this fake's `exchangeCallback` recognizes.
    func directCallbackToken(for email: String, kind: AccountAuthCallbackPayload.Kind = .signup) -> AccountAuthCallbackPayload? {
        guard let user = accountsByEmail[email]?.user else { return nil }
        return AccountAuthCallbackPayload(kind: kind, token: .direct(accessToken: "fake-access-\(user.id)", refreshToken: "fake-refresh-\(user.id)", expiresIn: 3600))
    }

    /// Folded into every minted token so a test can tell "the token issued at sign-in" apart
    /// from "the token issued by a later refresh" — without this, `signIn`/`refreshSession`
    /// always returned the exact same deterministic string for a given user, making it
    /// impossible to prove an operation actually used a freshly *refreshed* token.
    private var sessionIssueCounter = 0

    private func makeSession(for user: AccountUser) -> AccountSession {
        sessionIssueCounter += 1
        return AccountSession(
            accessToken: "fake-access-\(user.id)-\(sessionIssueCounter)",
            refreshToken: "fake-refresh-\(user.id)-\(sessionIssueCounter)",
            expiresAt: .now.addingTimeInterval(3600),
            user: user
        )
    }
}

// MARK: - KueUITests launch-argument installation (mirrors every other Fake* service)

extension FakeAccountProvider {
    static let uiTestLaunchArgument = "-uiTestFakeAccounts"

    @MainActor
    static func makeFromLaunchArguments() -> FakeAccountProvider? {
        guard ProcessInfo.processInfo.arguments.contains(uiTestLaunchArgument) else { return nil }
        return FakeAccountProvider()
    }
}
