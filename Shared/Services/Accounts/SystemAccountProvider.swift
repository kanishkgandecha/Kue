//
//  SystemAccountProvider.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Architecture." The one file that talks to Supabase over HTTP —
//  same "one file touches the real framework/service" shape `SystemCalendarProvider`
//  (EventKit)/`SystemOCRTextRecognizer` (Vision) already establish. Plain `URLSession` against
//  Supabase's own documented REST endpoints (GoTrue for auth, PostgREST for the `profiles`
//  table, Edge Functions for account deletion) — no third-party SDK dependency, matching this
//  project's existing zero-external-dependency footprint (every other integration in Kue —
//  EventKit, Vision, Speech, ActivityKit, CloudKit — is a first-party Apple framework called
//  directly; this is the same "one narrow, DI-seamed file" shape applied to one narrow REST
//  surface instead).
//
//  Never logs a request/response body, header, token, or full URL — see `redactedPath(_:)`
//  and every `catch` below, which only ever surface a short, typed `AccountError`.
//

import Foundation

nonisolated final class SystemAccountProvider: AccountProviding {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    init(configuration: SupabaseConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Sign up / sign in / sign out

    func signUp(email: String, password: String, username: String, displayName: String?) async throws -> AccountUser {
        let normalizedUsername = UsernamePolicy.normalize(username)
        var body: [String: Any] = [
            "email": email, "password": password,
            "data": ["username": normalizedUsername, "display_name": displayName as Any? ?? NSNull()],
        ]
        body["data"] = (body["data"] as! [String: Any]).filter { !($0.value is NSNull) || $0.key == "display_name" }
        let (data, response) = try await request(path: "/auth/v1/signup", method: "POST", body: body)
        try throwIfError(data: data, response: response)
        let decoded = try decode(GoTrueUserResponse.self, from: data)
        if decoded.identities?.isEmpty == true {
            // Supabase's own anti-enumeration behavior: signing up with an already-registered
            // email returns 200 with an empty `identities` array rather than a 4xx.
            throw AccountError.emailAlreadyRegistered
        }
        return try decoded.asAccountUser()
    }

    func signIn(email: String, password: String) async throws -> AccountSession {
        let (data, response) = try await request(
            path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")],
            method: "POST", body: ["email": email, "password": password]
        )
        try throwIfError(data: data, response: response)
        return try decode(GoTrueTokenResponse.self, from: data).asAccountSession()
    }

    func signOut(session accountSession: AccountSession) async throws {
        let (data, response) = try await request(path: "/auth/v1/logout", method: "POST", body: [:], accessToken: accountSession.accessToken)
        // A 401 here just means the token was already invalid server-side — signing out is
        // still a success from the caller's perspective (docs/32 "Sign-out cleanup").
        if response.statusCode == 401 { return }
        try throwIfError(data: data, response: response)
    }

    // MARK: - Password reset / confirmation resend

    func requestPasswordReset(email: String) async throws {
        let (data, response) = try await request(
            path: "/auth/v1/recover",
            query: [URLQueryItem(name: "redirect_to", value: AccountDeepLinkSupport.callbackURL.absoluteString)],
            method: "POST", body: ["email": email]
        )
        try throwIfError(data: data, response: response)
    }

    func resendConfirmationEmail(email: String) async throws {
        let (data, response) = try await request(
            path: "/auth/v1/resend",
            query: [URLQueryItem(name: "redirect_to", value: AccountDeepLinkSupport.callbackURL.absoluteString)],
            method: "POST", body: ["type": "signup", "email": email]
        )
        try throwIfError(data: data, response: response)
    }

    func updatePassword(_ newPassword: String, session accountSession: AccountSession) async throws {
        let (data, response) = try await request(path: "/auth/v1/user", method: "PUT", body: ["password": newPassword], accessToken: accountSession.accessToken)
        try throwIfError(data: data, response: response)
    }

    // MARK: - Session / user

    func refreshSession(_ accountSession: AccountSession) async throws -> AccountSession {
        let (data, response) = try await request(
            path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            method: "POST", body: ["refresh_token": accountSession.refreshToken]
        )
        if response.statusCode == 400 || response.statusCode == 401 { throw AccountError.refreshFailed }
        try throwIfError(data: data, response: response)
        return try decode(GoTrueTokenResponse.self, from: data).asAccountSession()
    }

    func fetchCurrentUser(session accountSession: AccountSession) async throws -> AccountUser {
        let (data, response) = try await request(path: "/auth/v1/user", method: "GET", body: nil, accessToken: accountSession.accessToken)
        try throwIfError(data: data, response: response)
        return try decode(GoTrueUserResponse.self, from: data).asAccountUser()
    }

    // MARK: - Profile (PostgREST `profiles` table)

    func fetchProfile(userID: UUID, session accountSession: AccountSession) async throws -> AccountProfile? {
        var request = try makeRequest(
            path: "/rest/v1/profiles",
            query: [URLQueryItem(name: "id", value: "eq.\(userID.uuidString)"), URLQueryItem(name: "select", value: "*")],
            method: "GET", body: nil, accessToken: accountSession.accessToken
        )
        request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        // PostgREST returns 406 for zero rows under the "single object" Accept header —
        // requirement F: "handling retries and partially-created states" right after
        // registration, before the server-side trigger has committed the row yet.
        if response.statusCode == 406 { return nil }
        try throwIfError(data: data, response: response)
        return try decode(ProfileRow.self, from: data).asAccountProfile()
    }

    func updateProfile(userID: UUID, username: String?, displayName: String?, session accountSession: AccountSession) async throws -> AccountProfile {
        var body: [String: Any] = [:]
        if let username { body["username"] = UsernamePolicy.normalize(username) }
        if let displayName { body["display_name"] = displayName }
        var request = try makeRequest(
            path: "/rest/v1/profiles", query: [URLQueryItem(name: "id", value: "eq.\(userID.uuidString)")],
            method: "PATCH", body: body, accessToken: accountSession.accessToken
        )
        request.setValue("return=representation,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try throwIfError(data: data, response: response)
        return try decode(ProfileRow.self, from: data).asAccountProfile()
    }

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        let (data, response) = try await request(
            path: "/rest/v1/rpc/is_username_available", method: "POST",
            body: ["p_username": UsernamePolicy.normalize(username)]
        )
        try throwIfError(data: data, response: response)
        guard let text = String(data: data, encoding: .utf8), let value = Bool(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AccountError.serverError
        }
        return value
    }

    // MARK: - Auth callback exchange

    func exchangeCallback(_ payload: AccountAuthCallbackPayload) async throws -> AccountSession {
        switch payload.token {
        case .direct(let accessToken, let refreshToken, let expiresIn):
            // Implicit-flow tokens are already valid — no exchange call needed, but hydrate
            // the real user record (`email_confirmed_at`/`created_at`) rather than fabricating
            // a partial one from the fragment alone.
            let partial = AccountSession(
                accessToken: accessToken, refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                user: AccountUser(id: UUID(), email: "", emailConfirmedAt: nil, createdAt: .now)
            )
            let user = try await fetchCurrentUser(session: partial)
            return AccountSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: partial.expiresAt, user: user)
        case .hash(let tokenHash):
            let (data, response) = try await request(
                path: "/auth/v1/verify", method: "POST",
                body: ["type": payload.kind.rawValue, "token_hash": tokenHash]
            )
            try throwIfError(data: data, response: response)
            return try decode(GoTrueTokenResponse.self, from: data).asAccountSession()
        }
    }

    // MARK: - Account deletion (Edge Function — never a service-role key in this app)

    func deleteAccount(session accountSession: AccountSession) async throws {
        let (data, response) = try await request(path: "/functions/v1/delete-account", method: "POST", body: [:], accessToken: accountSession.accessToken)
        try throwIfError(data: data, response: response)
    }

    // MARK: - HTTP plumbing

    private func makeRequest(path: String, query: [URLQueryItem] = [], method: String, body: [String: Any]?, accessToken: String? = nil) throws -> URLRequest {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw AccountError.unknown("Invalid request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.timeoutInterval = 20
        return request
    }

    private func request(path: String, query: [URLQueryItem] = [], method: String, body: [String: Any]?, accessToken: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try await perform(try makeRequest(path: path, query: query, method: method, body: body, accessToken: accessToken))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AccountError.serverError }
            return (data, http)
        } catch let error as AccountError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut:
                throw AccountError.offline
            default:
                throw AccountError.serverError
            }
        } catch {
            throw AccountError.serverError
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let decoded = try? JSONDecoder.kueAccountDecoder.decode(T.self, from: data) else {
            throw AccountError.serverError
        }
        return decoded
    }

    /// Maps a non-2xx response to the matching typed `AccountError` — the one place a raw
    /// Supabase error body is ever read, and only for its short `msg`/`error_description`
    /// field, never logged or otherwise surfaced verbatim without going through this mapping.
    private func throwIfError(data: Data, response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        if response.statusCode == 429 { throw AccountError.rateLimited }
        let errorBody = try? JSONDecoder().decode(GoTrueErrorResponse.self, from: data)
        let code = errorBody?.errorCode ?? errorBody?.error ?? ""
        let message = (errorBody?.msg ?? errorBody?.errorDescription ?? "").lowercased()

        if message.contains("email not confirmed") || code == "email_not_confirmed" {
            throw AccountError.emailNotConfirmed
        }
        if message.contains("invalid login credentials") || code == "invalid_grant" || code == "invalid_credentials" {
            throw AccountError.invalidCredentials
        }
        if message.contains("already registered") || message.contains("user already exists") {
            throw AccountError.emailAlreadyRegistered
        }
        if message.contains("password") && (message.contains("short") || message.contains("weak") || message.contains("at least")) {
            throw AccountError.weakPassword
        }
        if message.contains("username") && (message.contains("taken") || message.contains("duplicate") || message.contains("unique")) {
            throw AccountError.usernameTaken
        }
        if response.statusCode >= 500 { throw AccountError.serverError }
        // A short, safe message only — never the raw body (which could in principle echo
        // request content back).
        throw AccountError.unknown(errorBody?.msg ?? errorBody?.errorDescription ?? "Something went wrong (\(response.statusCode)).")
    }
}

// MARK: - Wire shapes (private to this file — nothing outside `Accounts/` ever sees these)

private struct GoTrueUserResponse: Decodable {
    var id: String
    var email: String?
    var emailConfirmedAt: String?
    var createdAt: String?
    var identities: [Identity]?

    struct Identity: Decodable {}

    enum CodingKeys: String, CodingKey {
        case id, email, identities
        case emailConfirmedAt = "email_confirmed_at"
        case createdAt = "created_at"
    }

    func asAccountUser() throws -> AccountUser {
        guard let uuid = UUID(uuidString: id) else { throw AccountError.serverError }
        return AccountUser(
            id: uuid, email: email ?? "",
            emailConfirmedAt: emailConfirmedAt.flatMap(ISO8601DateFormatter.kueFlexible.date(from:)),
            createdAt: createdAt.flatMap(ISO8601DateFormatter.kueFlexible.date(from:)) ?? .now
        )
    }
}

private struct GoTrueTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var user: GoTrueUserResponse

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", user
    }

    func asAccountSession() throws -> AccountSession {
        AccountSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)), user: try user.asAccountUser())
    }
}

private struct GoTrueErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?
    var errorCode: String?
    var msg: String?

    enum CodingKeys: String, CodingKey {
        case error, msg
        case errorDescription = "error_description"
        case errorCode = "error_code"
    }
}

private struct ProfileRow: Decodable {
    var id: String
    var username: String
    var displayName: String?
    var avatarUrl: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func asAccountProfile() throws -> AccountProfile {
        guard let uuid = UUID(uuidString: id) else { throw AccountError.serverError }
        return AccountProfile(
            id: uuid, username: username, displayName: displayName, avatarURL: avatarUrl.flatMap(URL.init(string:)),
            createdAt: ISO8601DateFormatter.kueFlexible.date(from: createdAt) ?? .now,
            updatedAt: ISO8601DateFormatter.kueFlexible.date(from: updatedAt) ?? .now
        )
    }
}

private extension ISO8601DateFormatter {
    /// Postgres/GoTrue timestamps usually carry fractional seconds, but not always (e.g. a
    /// value that happens to land exactly on a whole second) — one shared parser every wire-
    /// shape above uses, trying the fractional form first and falling back to the plain one,
    /// so a timestamp format mismatch can't silently drift between call sites.
    static let kueFlexible = KueFlexibleISO8601DateParser()
}

/// Not itself an `ISO8601DateFormatter` (that class's `formatOptions` isn't safely mutable
/// across concurrent use) — two fixed, pre-configured formatters tried in order instead.
private struct KueFlexibleISO8601DateParser {
    private let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func date(from string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }
}
