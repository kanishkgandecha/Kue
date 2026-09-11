//
//  AccountDeepLinkParsingTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Deep links." Pure parser tests for valid/invalid/malformed/
//  repeated/hostile-looking `kue://auth/callback` inputs (requirement J). Also proves every
//  pre-existing event/widget/Live Activity deep link still parses unchanged (requirement J:
//  "preserve all existing event/widget/Live Activity deep links").
//

import Testing
import Foundation
@testable import Kue

struct AccountDeepLinkParsingTests {
    // MARK: - Valid

    @Test func aValidSignupCallbackWithDirectTokensParses() {
        let url = URL(string: "kue://auth/callback#access_token=abc123&refresh_token=def456&expires_in=3600&token_type=bearer&type=signup")!
        let destination = KueDeepLink.parse(url)
        #expect(destination == .authCallback(AccountAuthCallbackPayload(kind: .signup, token: .direct(accessToken: "abc123", refreshToken: "def456", expiresIn: 3600))))
    }

    @Test func aValidRecoveryCallbackWithDirectTokensParses() {
        let url = URL(string: "kue://auth/callback#access_token=abc&refresh_token=def&expires_in=3600&type=recovery")!
        let destination = KueDeepLink.parse(url)
        #expect(destination == .authCallback(AccountAuthCallbackPayload(kind: .recovery, token: .direct(accessToken: "abc", refreshToken: "def", expiresIn: 3600))))
    }

    @Test func aValidTokenHashCallbackParses() {
        let url = URL(string: "kue://auth/callback?token_hash=xyz789&type=recovery")!
        let destination = KueDeepLink.parse(url)
        #expect(destination == .authCallback(AccountAuthCallbackPayload(kind: .recovery, token: .hash("xyz789"))))
    }

    @Test func everyRecognizedKindParses() {
        for kind in ["signup", "recovery", "magiclink", "invite", "email_change"] {
            let url = URL(string: "kue://auth/callback?token_hash=abc&type=\(kind)")!
            #expect(KueDeepLink.parse(url) != nil, "expected \(kind) to parse")
        }
    }

    // MARK: - Invalid / malformed / hostile

    @Test func wrongSchemeIsRejected() {
        let url = URL(string: "https://auth/callback#access_token=abc&refresh_token=def&expires_in=3600&type=signup")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func wrongHostIsRejected() {
        let url = URL(string: "kue://not-auth/callback?token_hash=abc&type=signup")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func wrongPathIsRejected() {
        let url = URL(string: "kue://auth/not-callback?token_hash=abc&type=signup")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func missingTypeIsRejected() {
        let url = URL(string: "kue://auth/callback#access_token=abc&refresh_token=def&expires_in=3600")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func unrecognizedTypeIsRejected() {
        let url = URL(string: "kue://auth/callback?token_hash=abc&type=totally_made_up")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func typeWithNoMatchingTokenShapeIsRejected() {
        // A `type` present but neither a direct-token fragment nor a `token_hash` query item —
        // malformed, not guessed at.
        let url = URL(string: "kue://auth/callback?type=signup")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func incompleteDirectTokenFragmentIsRejected() {
        // Missing `expires_in` — falls through to "no matching shape," never a partially
        // constructed payload with a garbage default.
        let url = URL(string: "kue://auth/callback#access_token=abc&refresh_token=def&type=signup")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func emptyTokenHashIsRejected() {
        let url = URL(string: "kue://auth/callback?token_hash=&type=recovery")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func aHostileLookingURLWithPathTraversalIsRejected() {
        let url = URL(string: "kue://auth/callback/../../event/00000000-0000-0000-0000-000000000000?token_hash=abc&type=signup")!
        // `url.path` for this is "/callback/../../event/..." (URL does not collapse dot
        // segments for a custom scheme) — never equal to the exact required "/callback".
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func aHostileLookingURLTryingToEmbedAnEventIDIsRejected() {
        // Requirement J: "ensure an authentication callback cannot navigate to or mutate an
        // arbitrary event" — even a URL shaped to *look* like it's trying to smuggle an event
        // id through this host never produces anything but `.authCallback` or `nil`; there is
        // no code path from this parser to `.event(_:)`.
        let url = URL(string: "kue://auth/callback?token_hash=abc&type=signup&event=00000000-0000-0000-0000-000000000000")!
        let destination = KueDeepLink.parse(url)
        if case .authCallback = destination {
            // Fine — the extra unrecognized query item is simply ignored.
        } else {
            #expect(destination == nil)
        }
    }

    // MARK: - Repeated / idempotency (parsing itself, not the coordinator's own handling)

    @Test func parsingTheSameURLTwiceProducesEqualPayloads() {
        let url = URL(string: "kue://auth/callback?token_hash=xyz&type=recovery")!
        #expect(KueDeepLink.parse(url) == KueDeepLink.parse(url))
    }

    // MARK: - Existing destinations still parse unchanged (requirement J)

    @Test func existingEventEditDeepLinkStillParses() {
        let id = UUID()
        #expect(KueDeepLink.parse(KueDeepLink.url(for: .event(id))) == .event(id))
    }

    @Test func existingQuickAddDeepLinkStillParses() {
        #expect(KueDeepLink.parse(KueDeepLink.url(for: .quickAdd)) == .quickAdd)
    }

    @Test func existingLockScreenSelectionDeepLinkStillParses() {
        #expect(KueDeepLink.parse(KueDeepLink.url(for: .lockScreenEventSelection)) == .lockScreenEventSelection)
    }

    @Test func existingTemplatesDeepLinkStillParses() {
        #expect(KueDeepLink.parse(KueDeepLink.url(for: .templates)) == .templates)
    }
}
