//
//  AccountKitTypes.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32-kue-3-accounts-and-backend-foundation.md. The Kue-owned
//  vocabulary for optional accounts, mirroring the exact shape `CalendarKitTypes.swift`/
//  `OCRKitTypes.swift`/`VoiceKitTypes.swift` already established: nothing outside
//  `Shared/Services/Accounts/` ever names a raw Supabase HTTP shape directly — every call
//  site reads only these types. Lives in `Shared/` (not `Kue/`) so `KueMac` can reuse the
//  entire stack verbatim, same reasoning `EventActions`/`EventCreationService`/etc. were
//  moved here in Kue 3.0 Phase 1.
//
//  Every type here is `nonisolated` — this module defaults to `@MainActor`
//  (`SWIFT_DEFAULT_ACTOR_ISOLATION`, see AGENTS.md's concurrency note) — so plain value types
//  compared via Swift Testing's `#expect` (which runs off the main actor) stay usable, the
//  same reason `NotificationCandidate`/`KueDeepLink.Destination` are marked this way.
//

import Foundation

// MARK: - Profile / user

/// The `profiles` row — see docs/32 "Database schema." Deliberately minimal: only fields this
/// phase's UI actually shows or edits.
nonisolated struct AccountProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var username: String
    var displayName: String?
    var avatarURL: URL?
    var createdAt: Date
    var updatedAt: Date
}

/// `auth.users`-derived identity fields this phase actually needs — never the full Supabase
/// user object, and never a password hash or any other secret.
nonisolated struct AccountUser: Codable, Equatable {
    var id: UUID
    var email: String
    var emailConfirmedAt: Date?
    var createdAt: Date

    var isEmailConfirmed: Bool { emailConfirmedAt != nil }
}

/// A live, refreshable Supabase session. **Never** persisted anywhere but `SecureStoring`
/// (Keychain) — see that protocol's own header. `expiresAt` is computed at construction time
/// from the server's `expires_in` seconds, not re-derived later, so a clock read anywhere else
/// only ever compares against this one already-resolved instant.
nonisolated struct AccountSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AccountUser

    /// A small buffer before the real expiry — matches `NotificationRuleValidator`'s own
    /// "decide slightly conservatively rather than exactly at the boundary" precedent typical
    /// of this codebase's time-sensitive checks.
    func isExpired(now: Date = .now) -> Bool { now >= expiresAt.addingTimeInterval(-30) }
}

extension AccountSession: CustomStringConvertible, CustomDebugStringConvertible {
    /// Requirement E: "Redact emails, tokens... from logs where practical." A session must
    /// never appear in a log line with its actual token values, even if some future call site
    /// accidentally interpolates one directly (`"\(session)"`) instead of reading a field.
    var description: String { "AccountSession(user: \(user.id), expiresAt: \(expiresAt), accessToken: <redacted>, refreshToken: <redacted>)" }
    var debugDescription: String { description }
}

// MARK: - Errors

/// Every failure `AccountProviding` can throw. Deliberately typed and closed — never a raw
/// `Error`/`NSError` bubbled up to the UI — so every call site can show honest, specific copy
/// (docs/32 "Failure states") rather than a generic "something went wrong."
nonisolated enum AccountError: Error, Equatable {
    case notConfigured
    case offline
    case invalidEmail
    case weakPassword
    case usernameInvalid(String)
    case usernameTaken
    case emailAlreadyRegistered
    case invalidCredentials
    case emailNotConfirmed
    case sessionExpired
    case refreshFailed
    case rateLimited
    case serverError
    /// Deliberately carries no raw response body/header — only ever a short, safe, already-
    /// sanitized description (never a token, header, or full URL). See `SystemAccountProvider
    /// .sanitizedServerMessage(_:)` for the one place a server error message is ever touched
    /// before reaching this case.
    case unknown(String)
}

extension AccountError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notConfigured: return "Accounts aren't configured in this build."
        case .offline: return "You're offline. Check your connection and try again."
        case .invalidEmail: return "Enter a valid email address."
        case .weakPassword: return "Choose a stronger password (at least 8 characters)."
        case .usernameInvalid(let reason): return reason
        case .usernameTaken: return "That username is already taken."
        case .emailAlreadyRegistered: return "An account with that email already exists."
        case .invalidCredentials: return "Incorrect email or password."
        case .emailNotConfirmed: return "Confirm your email before signing in."
        case .sessionExpired: return "Your session expired. Sign in again."
        case .refreshFailed: return "Couldn't refresh your session. Sign in again."
        case .rateLimited: return "Too many attempts. Wait a moment and try again."
        case .serverError: return "Something went wrong on the server. Try again shortly."
        case .unknown(let message): return message
        }
    }
}

// MARK: - Account state

/// The one account/session lifecycle every UI surface renders from — requirement D: "account
/// state transitions." A `@Observable` coordinator (`AccountCoordinator`) is the only thing
/// that ever mutates this; every view only reads it.
nonisolated enum AccountState: Equatable {
    /// No account, or a prior session was signed out. The default, permanent-if-never-used
    /// state — "account creation must remain optional."
    case signedOut
    /// A `signIn`/`signUp`/`refresh` call is in flight — used to disable submit buttons and
    /// show a loading indicator, never to block local data access.
    case authenticating
    /// Registered, but the confirmation email hasn't been confirmed yet — a real, distinct
    /// state, not folded into `.signedOut` or `.signedIn`.
    case awaitingEmailConfirmation(email: String)
    /// A `type=recovery` callback produced a session, but the user hasn't set a new password
    /// yet — distinct from `.signedIn` so the UI can require that one extra step first.
    case passwordRecovery(session: AccountSession)
    case signedIn(session: AccountSession, profile: AccountProfile?)
    /// The stored session's refresh token itself failed (revoked, expired past recovery) —
    /// distinct from `.signedOut` so the UI can say "your session expired," not silently act
    /// as if nothing was ever signed in.
    case sessionExpired
    /// Supabase configuration is absent, or the device is offline — requirement D: "the app
    /// must remain fully usable when Supabase is unreachable... the configuration is absent in
    /// a Personal build." Carries the reason so the UI can be honest about which.
    case unavailable(AccountUnavailableReason)

    var session: AccountSession? {
        switch self {
        case .signedIn(let session, _), .passwordRecovery(let session): return session
        default: return nil
        }
    }
}

nonisolated enum AccountUnavailableReason: Equatable, CustomStringConvertible {
    case configurationMissing
    case offline
    case serverError

    var description: String {
        switch self {
        case .configurationMissing: return "Accounts aren't set up in this build yet."
        case .offline: return "You're offline. Accounts need an internet connection."
        case .serverError: return "Kue's account service is temporarily unavailable."
        }
    }
}

// MARK: - Auth callback (deep link)

/// A parsed `kue://auth/callback` deep link — see `KueDeepLink.Destination.authCallback` and
/// docs/32 "Deep links." Two possible shapes depending on the Supabase email-template flow in
/// use (implicit tokens in the fragment, or a `token_hash` to exchange server-side) — see
/// `SystemAccountProvider.exchangeCallback(_:)` for how each is handled.
nonisolated struct AccountAuthCallbackPayload: Equatable {
    enum Kind: String {
        case signup, recovery, magiclink, invite
        case emailChange = "email_change"
    }

    enum Token: Equatable {
        case direct(accessToken: String, refreshToken: String, expiresIn: Int)
        case hash(String)
    }

    var kind: Kind
    var token: Token
}

extension AccountAuthCallbackPayload: CustomStringConvertible, CustomDebugStringConvertible {
    /// Requirement J: "never log complete callback URLs or embedded tokens." Even the parsed
    /// payload's own default description must never leak a token if some future call site
    /// interpolates it directly.
    var description: String {
        switch token {
        case .direct: return "AccountAuthCallbackPayload(kind: \(kind.rawValue), token: <redacted direct token>)"
        case .hash: return "AccountAuthCallbackPayload(kind: \(kind.rawValue), token: <redacted hash>)"
        }
    }
    var debugDescription: String { description }
}
