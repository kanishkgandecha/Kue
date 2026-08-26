//
//  URLContentFetcherTests.swift
//  KueTests
//
//  See docs/11-privacy-and-offline.md "What leaves the device" (Share Sheet URL fetch) and
//  docs/13-error-handling.md "Network failure". Tests the pure `<title>` extraction directly
//  against fixed HTML strings — no real network request, no `URLSession`.
//

import Testing
import Foundation
@testable import Kue

struct URLContentFetcherTests {
    @Test func extractsAPlainTitle() {
        let html = "<html><head><title>Salesforce Interview — Friday</title></head><body></body></html>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == "Salesforce Interview — Friday")
    }

    @Test func extractsATitleWithAttributesOnTheTag() {
        let html = "<html><head><title lang=\"en\">Team Offsite</title></head></html>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == "Team Offsite")
    }

    @Test func decodesCommonHTMLEntities() {
        let html = "<title>Rock &amp; Roll Night &#39;25</title>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == "Rock & Roll Night '25")
    }

    @Test func trimsWhitespaceAroundTheTitle() {
        let html = "<title>\n   Padded Title   \n</title>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == "Padded Title")
    }

    // MARK: - Malformed / missing (network failure fallback path)

    @Test func returnsNilWhenThereIsNoTitleTag() {
        let html = "<html><body>No title here</body></html>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == nil)
    }

    @Test func returnsNilForAnEmptyTitleTag() {
        let html = "<title></title>"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == nil)
    }

    @Test func returnsNilForTrulyMalformedMarkup() {
        let html = "<title>Unterminated"
        #expect(SystemURLContentFetcher.extractTitle(from: html) == nil)
    }

    // MARK: - Network failure fallback (fetchTitle degrades to nil, never throws)

    @Test func fetchTitleReturnsNilForAnUnreachableHost() async {
        // A reserved/non-routable address — resolves immediately to a connection failure
        // without depending on real internet access being available in the test environment.
        let url = URL(string: "https://198.51.100.1.invalid/")!
        let title = await SystemURLContentFetcher.shared.fetchTitle(for: url)
        #expect(title == nil)
    }
}
