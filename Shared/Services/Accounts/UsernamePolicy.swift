//
//  UsernamePolicy.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Username rules." Pure, deterministic, no network — the *client-
//  side* half of username validation. The Postgres `profiles_username_key` unique index (on
//  the already-normalized `username` column — see `supabase/migrations/`) is the actual
//  authority; this exists so the UI can reject an obviously-invalid username instantly,
//  without a round trip, and so `SystemAccountProvider`/tests share one normalization
//  definition instead of two independently-maintained ones drifting apart. "No race-prone
//  check-then-insert assumption" (requirement F) — a `.usernameTaken` error from the real
//  insert/RPC is still handled regardless of what this function said a moment earlier.
//

import Foundation

nonisolated enum UsernamePolicy {
    static let minimumLength = 3
    static let maximumLength = 20

    /// Deliberately short and unsurprising — real product/company/system names a user
    /// shouldn't be able to register as their own username. Checked against the *normalized*
    /// form, so case tricks don't bypass it.
    static let reservedUsernames: Set<String> = [
        "admin", "root", "support", "help", "api", "kue", "supabase",
        "null", "undefined", "settings", "profile", "me", "system", "moderator",
    ]

    /// Lowercases and trims — the single definition of "what a username actually is" once
    /// stored. Kue stores and displays usernames in this normalized form; there is no separate
    /// "display casing" (docs/32 "Username rules" — deliberately simple, avoids a second
    /// column/index just to remember a cosmetic casing preference).
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `nil` means valid. A non-nil string is the exact, user-facing reason (already suitable
    /// for `AccountError.usernameInvalid(_:)` — no further formatting needed at the call site).
    static func validationError(for raw: String) -> String? {
        let normalized = normalize(raw)
        guard normalized.count >= minimumLength else {
            return "Username must be at least \(minimumLength) characters."
        }
        guard normalized.count <= maximumLength else {
            return "Username must be \(maximumLength) characters or fewer."
        }
        guard let first = normalized.first, first.isLetter, first.isASCII else {
            return "Username must start with a letter."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Username can only contain lowercase letters, numbers, and underscores."
        }
        guard !normalized.contains("__") else {
            return "Username can't contain consecutive underscores."
        }
        guard !normalized.hasSuffix("_") else {
            return "Username can't end with an underscore."
        }
        guard !reservedUsernames.contains(normalized) else {
            return "That username is reserved."
        }
        return nil
    }

    static func isValid(_ raw: String) -> Bool { validationError(for: raw) == nil }
}
