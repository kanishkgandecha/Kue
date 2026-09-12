//
//  SupabaseStatisticsTransportTests.swift
//  KueTests
//
//  Kue 3.0 Phase 6 — docs/34 "Testing." Direct tests of `SupabaseStatisticsTransport` against a
//  deterministic, request-matched `URLProtocol` stub — same technique
//  `SupabaseSyncTransportTests.swift` already establishes (see that file's own header for why
//  a request-matched dispatcher is needed instead of a single fixed response). `@Suite
//  (.serialized)` for the identical reason: one shared static dispatcher, never run
//  concurrently with another test in this suite.
//

import Testing
import Foundation
@testable import Kue

private final class StatisticsRouteStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, Int, [String: String]))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, statusCode, headers) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SupabaseStatisticsTransportTests {
    private func makeTransport(handler: @escaping (URLRequest) -> (Data, Int, [String: String])) -> SupabaseStatisticsTransport {
        StatisticsRouteStub.handler = handler
        StatisticsRouteStub.capturedRequests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsRouteStub.self]
        let session = URLSession(configuration: configuration)
        let supabaseConfig = SupabaseConfiguration.make(urlString: "https://example.supabase.co", anonKey: String(repeating: "a", count: 40))!
        return SupabaseStatisticsTransport(configuration: supabaseConfig, session: session)
    }

    private func makePayload(bucketStart: String = "2026-03-02") -> StatisticsAggregatePayload {
        StatisticsAggregatePayload.make(from: .empty, bucketStart: Date(timeIntervalSince1970: 1_800_000_000), calendar: .current)
    }

    @Test func uploadSendsAnUpsertRequestWithTheMergeDuplicatesHeader() async {
        let transport = makeTransport { _ in (Data(), 201, [:]) }
        let result = await transport.upload(makePayload(), accessToken: "session-token")
        guard case .success = result else { Issue.record("expected success"); return }

        let sent = StatisticsRouteStub.capturedRequests.first
        #expect(sent?.url?.path == "/rest/v1/statistics_aggregates")
        #expect(sent?.httpMethod == "POST")
        #expect(sent?.url?.query?.contains("on_conflict=user_id,bucket_start") == true)
        #expect(sent?.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
    }

    @Test func uploadMapsA401ToNotAuthenticated() async {
        let transport = makeTransport { _ in (Data(), 401, [:]) }
        let result = await transport.upload(makePayload(), accessToken: "tok")
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error == .notAuthenticated)
    }

    @Test func uploadMapsA429ToRateLimited() async {
        let transport = makeTransport { _ in (Data(), 429, [:]) }
        let result = await transport.upload(makePayload(), accessToken: "tok")
        guard case .failure(.rateLimited) = result else { Issue.record("expected rateLimited, got \(result)"); return }
    }

    @Test func fetchRecentAggregatesDecodesEveryRowAndFiltersByUserID() async {
        let userID = UUID()
        let rows = [makePayload(bucketStart: "2026-02-23"), makePayload(bucketStart: "2026-03-02")]
        let transport = makeTransport { _ in (try! JSONEncoder().encode(rows), 200, [:]) }
        let result = await transport.fetchRecentAggregates(accessToken: "tok", userID: userID)
        guard case .success(let decoded) = result else { Issue.record("expected success"); return }
        #expect(decoded.count == 2)
        let sent = StatisticsRouteStub.capturedRequests.first
        #expect(sent?.url?.query?.contains("user_id=eq.\(userID.uuidString)") == true)
        #expect(sent?.httpMethod == "GET")
    }

    @Test func deleteAllSendsADeleteScopedToTheCallersOwnUserID() async {
        let userID = UUID()
        let transport = makeTransport { _ in (Data(), 204, [:]) }
        let result = await transport.deleteAll(accessToken: "tok", userID: userID)
        guard case .success = result else { Issue.record("expected success"); return }
        let sent = StatisticsRouteStub.capturedRequests.first
        #expect(sent?.httpMethod == "DELETE")
        #expect(sent?.url?.query == "user_id=eq.\(userID.uuidString)")
    }

    @Test func deleteAllMapsA5xxToServiceUnavailable() async {
        let transport = makeTransport { _ in (Data(), 503, [:]) }
        let result = await transport.deleteAll(accessToken: "tok", userID: UUID())
        guard case .failure(.serviceUnavailable) = result else { Issue.record("expected serviceUnavailable, got \(result)"); return }
    }

    @Test func malformedFetchResponseIsReportedAsUnknownNeverACrash() async {
        let transport = makeTransport { _ in (Data("not json".utf8), 200, [:]) }
        let result = await transport.fetchRecentAggregates(accessToken: "tok", userID: UUID())
        guard case .failure(.unknown) = result else { Issue.record("expected .unknown, got \(result)"); return }
    }
}
