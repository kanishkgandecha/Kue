//
//  CloudAccountProviding.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "F./G./R." A neutral account-state enum (not `CKAccountStatus`
//  directly) so this protocol's *signature* stays CloudKit-free and every fake/consumer in
//  Shared/ can use it without importing CloudKit — only `SystemCloudAccountProvider`
//  (Kue/Services/Sync/, app-only) actually imports CloudKit and translates.
//

import Foundation

nonisolated enum CloudAccountState: Equatable, Sendable {
    /// Signed in, no restriction — sync can proceed.
    case available
    case noAccount
    case restricted
    /// A real, distinct state from `noAccount`/`restricted` (docs/26 "F." case 6) — the
    /// account exists but the system couldn't confirm it right now (e.g. a transient
    /// keychain/daemon hiccup); worth a retry, not a "please sign in" prompt.
    case temporarilyUnavailable
    case couldNotDetermine
}

nonisolated protocol CloudAccountProviding: Sendable {
    func currentState() async -> CloudAccountState
    /// A privacy-safe, per-account (never per-Apple-ID-identity) fingerprint used only to
    /// detect *that* the signed-in account changed since the last successful sync — never
    /// logged, never the Apple ID itself (docs/26 "G.": "Do not log Apple IDs, account
    /// names, or private identifiers"). `nil` when no account is available.
    func currentAccountFingerprint() async -> String?
}

/// Kue/Services/Sync/SystemCloudAccountProvider.swift (app-only, imports CloudKit) is the
/// real implementation — declared there, not here, so this file stays CloudKit-free.

final class FakeCloudAccountProvider: CloudAccountProviding, @unchecked Sendable {
    var state: CloudAccountState
    var fingerprint: String?

    init(state: CloudAccountState = .available, fingerprint: String? = "fake-account-1") {
        self.state = state
        self.fingerprint = fingerprint
    }

    func currentState() async -> CloudAccountState { state }
    func currentAccountFingerprint() async -> String? { fingerprint }
}
