//
//  URLContentFetching.swift
//  Kue
//
//  See docs/11-privacy-and-offline.md "What leaves the device": "Share Sheet URL — Yes, the
//  URL itself is fetched over the network to retrieve page content; the fetched text is then
//  parsed on-device like any other NL input." This is the *one* network call anywhere in
//  Kue's input pipeline — everything downstream of it (the extracted title) goes through the
//  same on-device `NLParsing`/`NLDraftNormalizer` as typed text. DI seam (`URLContentFetching`)
//  so tests exercise failure/offline paths without a real network request.
//
//  Robustness fix (flagged in the Phase 10 review, before this was ever exercised on a real
//  device): a Share Extension runs under a *much* tighter memory jetsam limit than the host
//  app, and `URLSession.data(from:)` buffers the whole response into memory with no upper
//  bound and no built-in deadline beyond per-packet timeouts. A shared link pointing at a
//  multi-hundred-MB file (or a slow/stalled server) could jetsam the extension before
//  `fetchTitle` ever returns. Three bounds now apply, all before/during the request, never
//  after the fact: reject non-http(s) schemes outright (never open a connection for one),
//  cap total bytes actually read by cancelling the task once the cap is hit (title tags are
//  always near the top of `<head>` — 256 KB is generous), and a dedicated session with both
//  per-request and whole-resource timeouts (the latter is what actually bounds a slow trickle
//  that keeps resetting a per-packet timer). Byte-capping is delegate-based
//  (`URLSessionDataDelegate`), not `URLSession.bytes(for:)` — the latter doesn't reliably
//  cooperate with `URLProtocol`-based test stubbing (confirmed while writing this file's
//  tests), and the delegate path is the same mechanism real HTTP clients use for this exact
//  "abort once too big" pattern.
//

import Foundation

protocol URLContentFetching: Sendable {
    /// `nil` on any failure (offline, non-HTTP(S) URL, non-2xx response, undecodable body,
    /// no `<title>` found, response too large, timed out) — the caller falls back to manual
    /// entry per docs/13-error-handling.md "Network failure," it never surfaces a raw error.
    func fetchTitle(for url: URL) async -> String?
}

/// `nonisolated` — usable as a default parameter value under `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` (see AGENTS.md's concurrency note).
nonisolated final class SystemURLContentFetcher: URLContentFetching {
    static let shared = SystemURLContentFetcher()

    /// Title tags live in the first few KB of real-world pages; this leaves generous room
    /// without ever holding more than a fraction of a Share Extension's memory budget.
    static let maxBytesToRead = 256 * 1_024

    /// `internal`, not `private` — `URLContentFetcherTests` (a different file) drives the
    /// scheme-check + fetch + extract sequence directly against a pre-stubbed `URLRequest`,
    /// which the real `fetchTitle(for:)` can't accept (it always builds its own plain
    /// `URLRequest(url:)`, unable to carry `URLProtocol` stub properties).
    let session: URLSession

    private init() {
        // `.ephemeral` — no on-disk cache/cookies from a page whose only purpose here is a
        // one-off title scrape, consistent with "minimal data collection" (docs/11).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10 // resets per packet — catches "never responds at all"
        configuration.timeoutIntervalForResource = 15 // whole-transfer ceiling — catches a slow trickle that keeps resetting the above
        session = URLSession(configuration: configuration)
    }

    /// Test-only — lets `URLContentFetcherTests` inject a session pointed at a stub protocol
    /// without touching the real network, while `.shared` (used everywhere else) keeps its
    /// bounded, ephemeral configuration.
    init(session: URLSession) {
        self.session = session
    }

    func fetchTitle(for url: URL) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        let loader = CappedResponseLoader(maxBytes: Self.maxBytesToRead)
        let (data, response) = await loader.load(URLRequest(url: url), using: session)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return Self.extractTitle(from: html)
    }

    /// Deliberately minimal — a naive `<title>` scrape, not a general HTML/readability
    /// parser (out of scope for V1's "text/URL only" Share Sheet input). Not `private` so
    /// KueTests can exercise the parsing logic directly against fixed HTML strings, without
    /// a real network round trip.
    static func extractTitle(from html: String) -> String? {
        guard let tagStart = html.range(of: "<title", options: [.caseInsensitive]),
              let tagOpenEnd = html[tagStart.upperBound...].firstIndex(of: ">"),
              let tagClose = html.range(of: "</title>", options: [.caseInsensitive], range: html.index(after: tagOpenEnd)..<html.endIndex)
        else { return nil }

        let raw = html[html.index(after: tagOpenEnd)..<tagClose.lowerBound]
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The cap-crossing decision itself, pulled out as a plain value type independent of
/// `URLSession`/`URLProtocol` entirely — a hand-rolled `URLProtocol` stub delivers a whole
/// stubbed response in one `didLoad:` call (not the multi-chunk delivery a real network
/// transfer does), so a test built on top of the delegate/session plumbing can't actually
/// prove "the read stops partway through." This type is what that behavior really reduces
/// to, and it's fully driven by unit tests with plain `Data` chunks — no networking, no
/// stubbing fragility. Not `private` so `KueTests` can drive it directly.
/// `nonisolated` — driven directly from KueTests bodies that aren't `@MainActor` (see
/// AGENTS.md's concurrency note).
nonisolated struct ByteCapAccumulator {
    let maxBytes: Int
    private(set) var buffer = Data()
    private(set) var didExceedCap = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    /// No-ops once the cap has already been crossed — a caller that (incorrectly) kept
    /// delivering chunks after `didExceedCap` became true still can't grow `buffer` further.
    mutating func append(_ chunk: Data) {
        guard !didExceedCap else { return }
        buffer.append(chunk)
        if buffer.count >= maxBytes {
            didExceedCap = true
        }
    }
}

/// Runs one `URLSessionDataTask`, cancelling it the moment `ByteCapAccumulator` reports the
/// cap crossed rather than waiting for the transfer to finish naturally. Whatever was read
/// before a cancel (deliberate or from an error/timeout) is still handed back — a truncated
/// prefix is enough to find a `<title>` near the top of the document, and "give up entirely"
/// would throw away a perfectly usable partial read.
/// `internal`, not `private` — `URLContentFetcherTests` constructs one directly (see
/// `SystemURLContentFetcher.session`'s doc comment above for why).
final class CappedResponseLoader: NSObject, URLSessionDataDelegate {
    private var accumulator: ByteCapAccumulator
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse?), Never>?

    init(maxBytes: Int) {
        accumulator = ByteCapAccumulator(maxBytes: maxBytes)
    }

    func load(_ request: URLRequest, using session: URLSession) async -> (Data, URLResponse?) {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // A delegate-per-task session sharing the parent's configuration (timeouts,
            // ephemeral cache policy, and — in tests — the stub `protocolClasses`) but with
            // *this* loader as the delegate, since `session` itself has none.
            let delegatedSession = URLSession(configuration: session.configuration, delegate: self, delegateQueue: nil)
            delegatedSession.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        accumulator.append(data)
        if accumulator.didExceedCap {
            dataTask.cancel()
            finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
        session.finishTasksAndInvalidate()
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: (accumulator.buffer, response))
    }
}
