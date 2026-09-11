//
//  AccountSharedServiceSmokeTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 4 — same purpose as `MacSharedServiceSmokeTests.swift`'s own header: a spot
//  check that `Shared/Services/Accounts/` runs correctly reached from the `KueMac` module, not
//  a second copy of `KueTests/Accounts/`'s own exhaustive coverage of the same pure types. One
//  representative case per area — `FakeAccountProvider`/`FakeSecureStore` only, never real
//  networking or the real Keychain (requirement M).
//

import Testing
import Foundation
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all `KueMacTests` files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    @Test func usernamePolicyRejectsAReservedName() {
        #expect(UsernamePolicy.validationError(for: "admin") != nil)
        #expect(UsernamePolicy.isValid("kanishk_g") == true)
    }

    @Test func accountValidationRejectsAMalformedEmail() {
        #expect(AccountValidation.isValidEmail("not-an-email") == false)
        #expect(AccountValidation.isValidPassword("short") == false)
    }

    @Test func supabaseConfigurationMakeRejectsAPlaceholderKey() {
        #expect(SupabaseConfiguration.make(urlString: "https://example.supabase.co", anonKey: "YOUR_ANON_KEY") == nil)
        #expect(SupabaseConfiguration.make(urlString: "https://example.supabase.co", anonKey: String(repeating: "a", count: 40)) != nil)
    }

    @Test func profileStatisticsEngineHandlesEmptyEventsWithoutDividingByZero() {
        let stats = ProfileStatisticsEngine.compute(events: [], now: .now)
        #expect(stats.totalActiveEvents == 0)
        #expect(stats.completionRate == nil)
    }

    @Test func accountCoordinatorSignInWithTheFixtureAccountReachesSignedIn() async {
        let provider = FakeAccountProvider()
        let coordinator = AccountCoordinator(provider: provider, secureStore: FakeSecureStore())
        await coordinator.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        guard case .signedIn = coordinator.state else {
            Issue.record("Expected .signedIn, got \(coordinator.state)")
            return
        }
    }

    @Test func fakeSecureStoreRoundTripsASession() throws {
        let store = FakeSecureStore()
        let user = AccountUser(id: UUID(), email: "mac@kue.test", emailConfirmedAt: .now, createdAt: .now)
        let session = AccountSession(accessToken: "tok", refreshToken: "refresh", expiresAt: .now.addingTimeInterval(3600), user: user)
        try store.saveSession(session)
        #expect(try store.loadSession() == session)
    }

    @Test func accountDeepLinkSupportParsesARecoveryCallback() {
        let url = URL(string: "kue://auth/callback#access_token=abc&refresh_token=def&expires_in=3600&type=recovery")!
        let payload = AccountDeepLinkSupport.parse(url)
        #expect(payload?.kind == .recovery)
    }
}
