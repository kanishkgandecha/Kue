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

    // MARK: - Kue 2.0 Phase 10 (docs/24 "J.")

    @Test func quickAddURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .quickAdd)
        #expect(KueDeepLink.parse(url) == .quickAdd)
    }

    @Test func addFromTextURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .addFromText("Interview Friday at 10"))
        #expect(KueDeepLink.parse(url) == .addFromText("Interview Friday at 10"))
    }

    /// Requirement J: "percent-encoded natural-language input" — punctuation, whitespace, and
    /// non-ASCII text must all survive the URL round trip unchanged.
    @Test func addFromTextURLPercentEncodesAndRoundTripsSpecialCharacters() {
        let text = "Café meeting @ 3pm — bring déjà vu notes & \"quotes\"?"
        let url = KueDeepLink.url(for: .addFromText(text))
        #expect(KueDeepLink.parse(url) == .addFromText(text))
    }

    @Test func addFromTextRejectsEmptyText() {
        let url = URL(string: "kue://quick-add-text")!
        #expect(KueDeepLink.parse(url) == nil)
    }

    @Test func todayURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .today)
        #expect(KueDeepLink.parse(url) == .today)
    }

    @Test func searchURLWithQueryRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .search("interview"))
        #expect(KueDeepLink.parse(url) == .search("interview"))
    }

    @Test func searchURLWithNoQueryRoundTripsToNilQuery() {
        let url = KueDeepLink.url(for: .search(nil))
        #expect(KueDeepLink.parse(url) == .search(nil))
    }

    @Test func templatesURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .templates)
        #expect(KueDeepLink.parse(url) == .templates)
    }

    @Test func liveActivityFocusURLRoundTripsThroughParse() {
        let url = KueDeepLink.url(for: .liveActivityFocus)
        #expect(KueDeepLink.parse(url) == .liveActivityFocus)
    }

    /// Requirement J: "repeated URL delivery" — parsing the same URL twice must produce the
    /// identical result both times (no hidden mutable/one-shot state in `parse`).
    @Test func parsingTheSameURLTwiceProducesIdenticalResults() {
        let url = KueDeepLink.url(for: .event(UUID()))
        #expect(KueDeepLink.parse(url) == KueDeepLink.parse(url))
    }
}
