//
//  AccountProviding.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Architecture." The DI protocol every account-feature call site
//  reads through — same shape `CalendarProviding`/`OCRTextRecognizing` already establish.
//  `SystemAccountProvider` (the only file that talks to Supabase over HTTP) and
//  `FakeAccountProvider` (deterministic, in-memory, used by every unit/UI test) are its two
//  conformers.
//

import Foundation

protocol AccountProviding {
    /// Registers a new account. Email confirmation is required project-wide (see docs/32
    /// "Supabase configuration"), so this never returns a live session — only the pending
    /// `AccountUser` — the caller transitions to `.awaitingEmailConfirmation`.
    func signUp(email: String, password: String, username: String, displayName: String?) async throws -> AccountUser

    func signIn(email: String, password: String) async throws -> AccountSession

    /// Best-effort server-side revocation — the caller clears its own local session
    /// (`SecureStoring`) regardless of whether this throws (docs/32 "Sign-out cleanup": a
    /// network failure must never strand the user in a "still signed in" local state).
    func signOut(session: AccountSession) async throws

    func requestPasswordReset(email: String) async throws

    func resendConfirmationEmail(email: String) async throws

    /// Sets a new password using the temporary session a `type=recovery` callback produced.
    func updatePassword(_ newPassword: String, session: AccountSession) async throws

    func refreshSession(_ session: AccountSession) async throws -> AccountSession

    /// Re-fetches the live `auth.users` row — used right after a session is established so
    /// `emailConfirmedAt` reflects reality even if it changed since the session was minted.
    func fetchCurrentUser(session: AccountSession) async throws -> AccountUser

    /// `nil` if the row genuinely doesn't exist yet — a real, handled possibility right after
    /// registration if the server-side profile-creation trigger hasn't committed yet
    /// (requirement F: "handling retries and partially-created states"), not an error.
    func fetchProfile(userID: UUID, session: AccountSession) async throws -> AccountProfile?

    func updateProfile(userID: UUID, username: String?, displayName: String?, session: AccountSession) async throws -> AccountProfile

    /// Calls the `is_username_available` RPC (docs/32 "Database schema") — never a raw
    /// check-then-insert client-side assumption; the actual unique index remains authoritative
    /// regardless of what this returns a moment before a real registration/edit.
    func isUsernameAvailable(_ username: String) async throws -> Bool

    /// Exchanges a parsed `kue://auth/callback` payload for a session — see
    /// `AccountAuthCallbackPayload`'s own header for the two possible shapes.
    func exchangeCallback(_ payload: AccountAuthCallbackPayload) async throws -> AccountSession

    /// Requirement K: calls the smallest secure server-side path (a Supabase Edge Function)
    /// that authenticates the caller from `session` and deletes only that caller's own
    /// account — never a service-role key in this app, never a client-side fake.
    func deleteAccount(session: AccountSession) async throws
}
