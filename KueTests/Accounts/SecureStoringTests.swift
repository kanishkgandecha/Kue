//
//  SecureStoringTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Testing": "secure-store behavior through a fake abstraction."
//  `FakeSecureStore` is what every other account test uses; `SystemSecureStore` gets one real,
//  narrow round-trip test here against the Simulator's own real Keychain (available and
//  functional in the iOS Simulator, unlike EventKit/Vision/Speech's real hardware/data
//  dependencies) — cleans up after itself unconditionally via `defer`.
//

import Testing
import Foundation
@testable import Kue

struct SecureStoringTests {
    /// `expiresAt`/`createdAt` are rounded to millisecond precision — the most any ISO 8601
    /// text representation (`SecureStoring.swift`'s own `kueAccountDateFormatter`) can carry.
    /// A `Date`'s underlying `TimeInterval` has finer-than-millisecond precision, so comparing
    /// an *unrounded* fixture against one that has been through a real JSON-text round trip
    /// (`SystemSecureStore`'s Keychain storage, below) would never `==` even though nothing is
    /// actually wrong — this is a fixture-precision detail, not something production code
    /// needs to guarantee (`AccountSession.isExpired(now:)`'s own `>=` comparison is unaffected
    /// by sub-millisecond rounding either way).
    private func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private func makeSession(id: UUID = UUID()) -> AccountSession {
        AccountSession(
            accessToken: "access-\(id)", refreshToken: "refresh-\(id)", expiresAt: roundedToMillisecond(.now.addingTimeInterval(3600)),
            user: AccountUser(id: id, email: "a@b.com", emailConfirmedAt: roundedToMillisecond(.now), createdAt: roundedToMillisecond(.now))
        )
    }

    // MARK: - FakeSecureStore

    @Test func fakeStoreRoundTripsASession() throws {
        let store = FakeSecureStore()
        let session = makeSession()
        try store.saveSession(session)
        #expect(try store.loadSession() == session)
    }

    @Test func fakeStoreLoadWithNothingSavedReturnsNil() throws {
        let store = FakeSecureStore()
        #expect(try store.loadSession() == nil)
    }

    @Test func fakeStoreClearRemovesTheSession() throws {
        let store = FakeSecureStore()
        try store.saveSession(makeSession())
        try store.clearSession()
        #expect(try store.loadSession() == nil)
    }

    @Test func fakeStoreSavingTwiceOverwritesRatherThanAccumulating() throws {
        let store = FakeSecureStore()
        try store.saveSession(makeSession())
        let second = makeSession()
        try store.saveSession(second)
        #expect(try store.loadSession() == second)
    }

    @Test func fakeStoreCanSimulateAKeychainFailure() {
        let store = FakeSecureStore()
        store.errorToThrow = SecureStoreError.keychainFailed(-25300)
        #expect(throws: (any Error).self) { try store.saveSession(self.makeSession()) }
        #expect(throws: (any Error).self) { try store.loadSession() }
        #expect(throws: (any Error).self) { try store.clearSession() }
    }

    // MARK: - SystemSecureStore (real Simulator Keychain — narrow, self-cleaning)

    @Test func systemStoreRoundTripsASessionThroughTheRealKeychain() throws {
        let store = SystemSecureStore.shared
        defer { try? store.clearSession() }
        let session = makeSession()
        try store.saveSession(session)
        #expect(try store.loadSession() == session)
    }

    @Test func systemStoreClearRemovesFromTheRealKeychain() throws {
        let store = SystemSecureStore.shared
        try store.saveSession(makeSession())
        try store.clearSession()
        #expect(try store.loadSession() == nil)
    }

    @Test func systemStoreSavingTwiceOverwritesRatherThanFailing() throws {
        let store = SystemSecureStore.shared
        defer { try? store.clearSession() }
        try store.saveSession(makeSession())
        let second = makeSession()
        try store.saveSession(second) // must not throw errSecDuplicateItem
        #expect(try store.loadSession() == second)
    }
}
