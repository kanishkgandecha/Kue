//
//  KueDeepLinkTests.swift
//  KueTests
//
//  Covers docs/22-expanded-and-dedicated-widgets.md "E." — deep-link construction/parsing
//  must round-trip exactly, and parsing must degrade safely on anything malformed/foreign
//  (requirement I.7: "validate deep links and handle missing identifiers safely").
//

import Testing
import Foundation
@testable import Kue

struct KueDeepLinkTests {
    @Test func eventURLRoundTripsThroughParse() {
        let id = UUID()
        let url = KueDeepLink.url(for: .event(id))
        #expect(KueDeepLink.parse(url) == .event(id))
    }

    @Test func dedicatedCountdownHelpURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .dedicatedCountdownHelp)
        #expect(KueDeepLink.parse(url) == .dedicatedCountdownHelp)
    }

    @Test func parseRejectsAForeignScheme() {
        let url = URL(string: "https://example.com/event/\(UUID().uuidString)")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func parseRejectsAMalformedEventIdentifier() {
        let url = URL(string: "kue://event/not-a-real-uuid")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func parseRejectsAnUnrecognizedHost() {
        let url = URL(string: "kue://something-else")!
        #expect(KueDeepLink.parse(url) == nil)
    }
}
