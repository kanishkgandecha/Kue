//
//  AccountValidation.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Registration validation." Pure, client-side pre-checks for
//  email/password — Supabase's own Auth server is still the actual authority (a client-side
//  pass never guarantees the server accepts it), so `SystemAccountProvider` still maps a real
//  4xx from Supabase to the matching `AccountError` regardless of what this validated locally.
//  This exists purely to give instant, offline field-level feedback (requirement H: "field-
//  level validation") before ever making a network call.
//

import Foundation

nonisolated enum AccountValidation {
    /// A deliberately simple, conservative check — "contains an @ with a non-empty name and a
    /// domain with at least one dot," not a full RFC 5322 parser (which would reject or accept
    /// real addresses inconsistently anyway). The server is the real authority on deliverable
    /// addresses; this only catches obvious typos before a round trip.
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let atIndex = trimmed.firstIndex(of: "@") else { return false }
        let name = trimmed[trimmed.startIndex..<atIndex]
        let domain = trimmed[trimmed.index(after: atIndex)...]
        guard !name.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !domain.contains(" ") && !name.contains(" ")
    }

    static let minimumPasswordLength = 8

    /// Matches Supabase Auth's own default minimum (8 characters) — deliberately not a more
    /// elaborate complexity rule (uppercase/digit/symbol requirements are a well-documented
    /// usability/security anti-pattern; length is what actually matters for password strength).
    static func isValidPassword(_ password: String) -> Bool {
        password.count >= minimumPasswordLength
    }
}
