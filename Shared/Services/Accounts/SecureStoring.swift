//
//  SecureStoring.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Secure token storage." The DI seam around the Keychain, same
//  shape `CalendarProviding`/`OCRTextRecognizing`/`VoiceAuthorizationChecking` already
//  establish: a protocol, one real `Security`-framework-touching implementation
//  (`SystemSecureStore`, the *only* file in this project that imports `Security`), and a
//  deterministic in-memory fake for tests (requirement M: "secure-store behavior through a
//  fake abstraction"). `AccountSession` (access token, refresh token) is the one thing this
//  phase stores here — requirement E: "Do not store access or refresh tokens in SwiftData,
//  App Group `UserDefaults`, plain files, logs, screenshots, backups, or analytics." Nothing
//  outside this file ever calls a `kSecClass*`/`SecItem*` API directly.
//
//  Not shared via the App Group Keychain access group on purpose: `KueMac` has no App Group at
//  all (docs/29 "C."), and cross-device session sharing isn't a Phase 4 goal (no sync yet,
//  requirement: "does not implement event/task synchronization... yet") — each platform's own
//  per-app Keychain item is exactly the right scope for "this device's own session."
//

import Foundation
import Security

protocol SecureStoring {
    func saveSession(_ session: AccountSession) throws
    func loadSession() throws -> AccountSession?
    func clearSession() throws
}

nonisolated enum SecureStoreError: Error, Equatable {
    case encodingFailed
    case keychainFailed(OSStatus)
}

/// The one file that imports `Security` — every other file in the app reads sessions only
/// through `SecureStoring`.
nonisolated final class SystemSecureStore: SecureStoring {
    static let shared = SystemSecureStore()

    /// Distinct per bundle identifier automatically (Keychain items are already scoped per
    /// app/extension by `kSecAttrService` + the app's own access group) — Kue, KueMac, and the
    /// iOS extensions never see each other's stored session, matching "each device/process
    /// keeps its own session" above.
    private let service = "com.kanishkgandecha.Kue.account-session"
    private let account = "current-session"

    private init() {}

    func saveSession(_ session: AccountSession) throws {
        guard let data = try? JSONEncoder.kueAccountEncoder.encode(session) else {
            throw SecureStoreError.encodingFailed
        }
        var query = baseQuery
        SecItemDelete(query as CFDictionary) // idempotent overwrite — never two stale items
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureStoreError.keychainFailed(status) }
    }

    func loadSession() throws -> AccountSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureStoreError.keychainFailed(status)
        }
        return try? JSONDecoder.kueAccountDecoder.decode(AccountSession.self, from: data)
    }

    func clearSession() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychainFailed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory only — never touches the real Keychain. Used by `FakeAccountProvider`-backed
/// tests and every UI test (requirement M: "Use fake account providers only — never real
/// Supabase credentials").
final class FakeSecureStore: SecureStoring {
    private(set) var storedSession: AccountSession?
    /// Lets a test simulate a real Keychain failure (e.g. device locked) without needing an
    /// actual locked device.
    var errorToThrow: Error?

    func saveSession(_ session: AccountSession) throws {
        if let errorToThrow { throw errorToThrow }
        storedSession = session
    }

    func loadSession() throws -> AccountSession? {
        if let errorToThrow { throw errorToThrow }
        return storedSession
    }

    func clearSession() throws {
        if let errorToThrow { throw errorToThrow }
        storedSession = nil
    }
}

/// Plain `.iso8601` (both here and Foundation's own default) truncates to whole seconds — a
/// real, found-via-test precision loss: encoding then decoding an `AccountSession` through
/// `SystemSecureStore`'s Keychain round trip silently changed its `expiresAt` by a fraction of
/// a second, breaking exact `Equatable` comparisons (harmless for `isExpired(now:)`'s own `>=`
/// check, but a real correctness gap for anything — including this file's own tests — that
/// expects a round-tripped session to `==` the original). `withFractionalSeconds` fixes it.
private let kueAccountDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

extension JSONEncoder {
    static let kueAccountEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(kueAccountDateFormatter.string(from: date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let kueAccountDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = kueAccountDateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
            }
            return date
        }
        return decoder
    }()
}
