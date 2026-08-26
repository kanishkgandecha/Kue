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

/// Serves a fixed, in-memory response for any request — lets the "happy path"/status-code
/// tests below exercise `SystemURLContentFetcher.fetchTitle`'s real session/delegate plumbing
/// without a network call. Response data/status ride on the *request* (via `URLProtocol`'s
/// property mechanism), not shared mutable state, since Swift Testing runs `@Test`s in
/// parallel by default — a shared `static var` here would race across tests.
private final class StubURLProtocol: URLProtocol {
    private static let dataKey = "KueStubResponseData"
    private static let statusKey = "KueStubStatusCode"

    static func stubbedRequest(url: URL, data: Data, statusCode: Int) -> URLRequest {
        let mutableRequest = ((URLRequest(url: url)) as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(data, forKey: dataKey, in: mutableRequest)
        URLProtocol.setProperty(statusCode, forKey: statusKey, in: mutableRequest)
        return mutableRequest as URLRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = URLProtocol.property(forKey: Self.dataKey, in: request) as? Data ?? Data()
        let statusCode = URLProtocol.property(forKey: Self.statusKey, in: request) as? Int ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedFetcher() -> SystemURLContentFetcher {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return SystemURLContentFetcher(session: URLSession(configuration: configuration))
}

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

    // MARK: - Robustness (flagged in review): scheme rejection, response-size cap, timeouts

    @Test func fetchTitleRejectsNonHTTPSchemesBeforeOpeningAnyConnection() async {
        for scheme in ["file", "ftp", "mailto", "javascript"] {
            let url = URL(string: "\(scheme)://example.com/page")!
            let title = await SystemURLContentFetcher.shared.fetchTitle(for: url)
            #expect(title == nil, "expected nil for \(scheme)://")
        }
    }

    @Test func fetchTitleFindsATitleWellWithinTheSizeCap() async {
        let fetcher = makeStubbedFetcher()
        let data = Data("<html><head><title>Small Page</title></head></html>".utf8)
        let request = StubURLProtocol.stubbedRequest(url: URL(string: "https://example.com/small")!, data: data, statusCode: 200)
        let title = await fetcher.fetchTitle(for: request.url!, request: request)
        #expect(title == "Small Page")
    }

    @Test func fetchTitleReturnsNilForANonSuccessStatusCode() async {
        let fetcher = makeStubbedFetcher()
        let data = Data("<title>Not Found</title>".utf8)
        let request = StubURLProtocol.stubbedRequest(url: URL(string: "https://example.com/missing")!, data: data, statusCode: 404)
        let title = await fetcher.fetchTitle(for: request.url!, request: request)
        #expect(title == nil)
    }

    // The cap-crossing decision itself — see `ByteCapAccumulator`'s own doc comment for why
    // this is tested directly rather than through a stubbed `URLProtocol`: a hand-rolled stub
    // delivers its whole response in one `didLoad:` call, not the multi-chunk delivery a real
    // transfer does, so it can't actually exercise "stops partway through."

    @Test func accumulatorStopsGrowingOnceTheCapIsReached() {
        var accumulator = ByteCapAccumulator(maxBytes: 10)
        accumulator.append(Data(count: 6))
        #expect(!accumulator.didExceedCap)
        #expect(accumulator.buffer.count == 6)

        accumulator.append(Data(count: 6))
        #expect(accumulator.didExceedCap)
        #expect(accumulator.buffer.count == 12) // the crossing chunk is kept — still a usable prefix

        // A chunk delivered after the cap already tripped must never grow the buffer further.
        accumulator.append(Data(count: 1_000))
        #expect(accumulator.buffer.count == 12)
    }

    @Test func accumulatorNeverTripsWhenTotalStaysUnderTheCap() {
        var accumulator = ByteCapAccumulator(maxBytes: 100)
        accumulator.append(Data(count: 40))
        accumulator.append(Data(count: 40))
        #expect(!accumulator.didExceedCap)
        #expect(accumulator.buffer.count == 80)
    }
}

private extension SystemURLContentFetcher {
    /// Test-only overload — `fetchTitle(for:)` always builds its own plain `URLRequest(url:)`,
    /// which can't carry `StubURLProtocol`'s per-request stubbed properties. This mirrors its
    /// scheme-check + fetch + extract sequence against an explicit, pre-stubbed request.
    func fetchTitle(for url: URL, request: URLRequest) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let loader = CappedResponseLoader(maxBytes: Self.maxBytesToRead)
        let (data, response) = await loader.load(request, using: session)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return Self.extractTitle(from: html)
    }
}
