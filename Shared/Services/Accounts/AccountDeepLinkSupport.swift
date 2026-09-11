//
//  AccountDeepLinkSupport.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Deep links." The parsing half of `kue://auth/callback` handling
//  — kept in its own file (not `KueDeepLink.swift` itself) since it's meaningfully larger than
//  every other single-case parse arm there and account-specific; `KueDeepLink.swift` only
//  gains one new `Destination` case plus a two-line dispatch to `parseAuthCallback(_:)` below.
//  Pure — no networking, no SwiftUI — exercised directly by
//  `AccountDeepLinkParsingTests.swift` with valid/invalid/malformed/hostile URLs.
//

import Foundation

nonisolated enum AccountDeepLinkSupport {
    /// The exact redirect URL configured in the Supabase dashboard (Authentication → URL
    /// Configuration) — see docs/32 "Supabase configuration." One literal, read everywhere
    /// this needs it (email-template `redirect_to` params, the parser's own host/path check)
    /// rather than a second copy.
    static let callbackURL = URL(string: "kue://auth/callback")!
    static let host = "auth"
    static let path = "/callback"

    /// `nil` for anything that isn't genuinely this exact callback shape — requirement J:
    /// "reject malformed or unrelated URLs." Validates scheme (checked by the caller,
    /// `KueDeepLink.parse`, before this is ever called) + host + path explicitly; never
    /// guesses at an unrecognized shape.
    static func parse(_ url: URL) -> AccountAuthCallbackPayload? {
        guard url.host == host, url.path == path else { return nil }

        // Supabase's implicit-flow links put tokens in the URL *fragment* (`#access_token=...`),
        // which `URLComponents.queryItems` never parses — decoded by hand here. The PKCE/OTP
        // shape (`token_hash`) travels as an ordinary query item instead.
        let fragmentPairs = fragmentKeyValuePairs(of: url)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        guard let kindRaw = fragmentPairs["type"] ?? queryItems.first(where: { $0.name == "type" })?.value,
              let kind = AccountAuthCallbackPayload.Kind(rawValue: kindRaw)
        else { return nil }

        if let accessToken = fragmentPairs["access_token"], let refreshToken = fragmentPairs["refresh_token"],
           let expiresInString = fragmentPairs["expires_in"], let expiresIn = Int(expiresInString),
           !accessToken.isEmpty, !refreshToken.isEmpty {
            return AccountAuthCallbackPayload(kind: kind, token: .direct(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn))
        }
        if let tokenHash = queryItems.first(where: { $0.name == "token_hash" })?.value, !tokenHash.isEmpty {
            return AccountAuthCallbackPayload(kind: kind, token: .hash(tokenHash))
        }
        // A `type` with no matching token shape — a malformed or hostile URL (requirement J's
        // own "malformed... and hostile-looking inputs" test category), never guessed at.
        return nil
    }

    private static func fragmentKeyValuePairs(of url: URL) -> [String: String] {
        guard let fragment = url.fragment, !fragment.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            result[key] = value
        }
        return result
    }
}
