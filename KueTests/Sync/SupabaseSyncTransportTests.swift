//
//  SupabaseSyncTransportTests.swift
//  KueTests
//
//  Kue 3.0 Phase 5 correction (requirement 6 — the disclosed gap the original Phase 5 report
//  never closed): direct tests of `SupabaseSyncTransport` itself — the one file that talks real
//  HTTP for sync — against a deterministic `URLProtocol` stub, never a real network call and
//  never routed through `SyncCoordinator`/`FakeSyncTransport` (every other sync test's own
//  level). Same "stub the request, not the network" technique `URLContentFetcherTests.swift`
//  already establishes, extended from a single fixed response to a request-matched dispatcher
//  (`RouteStubURLProtocol.handler`), because `SupabaseSyncTransport` builds every `URLRequest`
//  itself from configuration rather than accepting a pre-built one a test could tag directly.
//
//  `@Suite(.serialized)`: `RouteStubURLProtocol.handler` is one shared dispatcher, set by each
//  test immediately before it drives a real call through the transport — safe only because
//  Swift Testing never runs two tests of this suite concurrently, exactly like
//  `SyncCoordinatorTests`'s own `.syncPreferenceSerialized` is serialized for the same shared-
//  mutable-state reason.
//

import Testing
import Foundation
@testable import Kue

/// Matches any request; a per-test `handler` closure decides the response from the request's
/// own URL/method/body, so one stub class can stand in for the whole PostgREST/RPC surface
/// `SupabaseSyncTransport` talks to, not just one fixed canned reply.
private final class RouteStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, Int, [String: String]))?
    /// Every request this stub actually saw, in order — lets a test assert on the exact JSON
    /// body/path/method `SupabaseSyncTransport` sent, not just on the response it got back.
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
struct SupabaseSyncTransportTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTransport(handler: @escaping (URLRequest) -> (Data, Int, [String: String])) -> SupabaseSyncTransport {
        RouteStubURLProtocol.handler = handler
        RouteStubURLProtocol.capturedRequests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouteStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let supabaseConfig = SupabaseConfiguration.make(urlString: "https://example.supabase.co", anonKey: String(repeating: "a", count: 40))!
        return SupabaseSyncTransport(configuration: supabaseConfig, session: session)
    }

    private func jsonBody(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody ?? request.httpBodyStream.map({ Data(reading: $0) }),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func minimalEventRecord(id: UUID = UUID()) -> EventSyncRecord {
        EventSyncRecord(
            id: id, title: "Interview", eventType: "interview", startDate: now, endDate: nil,
            estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
            location: nil, notes: nil, source: "manual", priority: "medium",
            isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
            recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
            isSkipped: false, skippedAt: nil, tasks: [], schedule: nil, widgetConfiguration: nil,
            createdAt: now, updatedAt: now, revision: 0, clientMutationID: UUID()
        )
    }

    // MARK: - ensureReady

    @Test func ensureReadySucceedsOn200AndSendsTheAnonKeyNeverAnAccessToken() async {
        let transport = makeTransport { _ in (Data(), 200, [:]) }
        let result = await transport.ensureReady()
        guard case .success = result else { Issue.record("expected success"); return }
        let sent = RouteStubURLProtocol.capturedRequests.first
        // `ensureReady` deliberately probes with the anon key, never a real session token — it
        // must work identically whether or not a user is even signed in yet.
        #expect(sent?.value(forHTTPHeaderField: "apikey")?.count == 40)
        #expect(sent?.value(forHTTPHeaderField: "Authorization")?.hasSuffix(String(repeating: "a", count: 40)) == true)
    }

    @Test func ensureReadyMapsA401ToNotAuthenticated() async {
        let transport = makeTransport { _ in (Data(), 401, [:]) }
        let result = await transport.ensureReady()
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error == .notAuthenticated)
    }

    // MARK: - push_event_graph — request shape, snake/camel + child graph, response decoding

    @Test func pushEventGraphSendsTheFullEventGraphIncludingTasksScheduleAndNotificationRules() async {
        var record = minimalEventRecord()
        record.tasks = [TaskSyncPayload(id: UUID(), title: "Prep", dueDate: now, isCompleted: false, completedAt: nil, offsetLabel: "1 day before", sortOrder: 0)]
        record.schedule = SchedulePayload(
            id: UUID(), templateType: "interview",
            rules: [ScheduleRulePayload(offset: DateComponents(day: -1), taskTitle: "Prep", isTimeSensitive: true)],
            isCustom: false, generatedAt: now
        )
        record.notificationRules = [NotificationRuleSyncPayload(
            id: UUID(), taskID: nil, anchor: "eventStart", offsetDirection: "before", offsetQuantity: 30,
            offsetUnit: "minutes", absoluteDate: nil, isEnabled: true, customTitle: nil, customBody: nil,
            sound: "defaultSound", interruptionPreference: "active", snoozeMinutes: nil, sortOrder: 0,
            createdAt: now, updatedAt: now
        )]
        record.revision = 3

        let transport = makeTransport { _ in
            (Data(#"{"id": "\#(record.id.uuidString)", "revision": 4, "conflict": false}"#.utf8), 200, [:])
        }
        let result = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "session-token")
        #expect(result.succeededEventIDs == [record.id])
        #expect(result.newRevisionsByEventID[record.id] == 4)

        let sent = RouteStubURLProtocol.capturedRequests.first
        #expect(sent?.url?.path == "/rest/v1/rpc/push_event_graph")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        let payload = jsonBody(sent!)["payload"] as? [String: Any]
        #expect(payload?["expectedRevision"] as? Int64 == 3)
        #expect((payload?["tasks"] as? [[String: Any]])?.first?["offsetLabel"] as? String == "1 day before")
        #expect((payload?["notificationRules"] as? [[String: Any]])?.first?["anchor"] as? String == "eventStart")
        // The exact bug this file's own review found and fixed elsewhere in Phase 5: `offset`
        // (a `DateComponents`) must survive the round trip, not be silently dropped.
        let scheduleRules = (payload?["schedule"] as? [String: Any])?["rules"] as? [[String: Any]]
        #expect((scheduleRules?.first?["offset"] as? [String: Any])?["day"] as? Int == -1)
    }

    @Test func pushEventGraphReportsAConflictWithoutTreatingItAsAFailure() async {
        let record = minimalEventRecord()
        let transport = makeTransport { _ in (Data(#"{"id": "\#(record.id.uuidString)", "conflict": true}"#.utf8), 200, [:]) }
        let result = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "tok")
        #expect(result.conflictedEventIDs == [record.id])
        #expect(result.failedEvents.isEmpty)
        #expect(result.succeededEventIDs.isEmpty)
    }

    /// Idempotent-replay contract (requirement 3): the server returns the exact same envelope
    /// shape for a genuine success and for a recognized replay of an already-applied mutation —
    /// the transport's own job is only to trust that envelope, never to second-guess it by
    /// comparing revisions itself. Calling twice with a stub that returns the identical revision
    /// both times must report success both times, never a spurious conflict on the second call.
    @Test func repeatedIdenticalSuccessResponsesAreBothReportedAsSuccessNeverAConflict() async {
        let record = minimalEventRecord()
        let transport = makeTransport { _ in (Data(#"{"id": "\#(record.id.uuidString)", "revision": 1, "conflict": false}"#.utf8), 200, [:]) }
        let first = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "tok")
        let second = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "tok")
        #expect(first.succeededEventIDs == [record.id])
        #expect(second.succeededEventIDs == [record.id])
        #expect(first.newRevisionsByEventID[record.id] == 1)
        #expect(second.newRevisionsByEventID[record.id] == 1) // untouched — not bumped by the replay
    }

    @Test func pushEventGraphMapsAnRPCLevelErrorFieldToValidationFailed() async {
        let record = minimalEventRecord()
        let transport = makeTransport { _ in (Data(#"{"id": "\#(record.id.uuidString)", "error": "push_failed"}"#.utf8), 200, [:]) }
        let result = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "tok")
        #expect(result.failedEvents.first?.error == .validationFailed)
    }

    @Test func pushEventGraphTreatsMalformedResponseBodyAsAnUnknownFailureNeverACrash() async {
        let record = minimalEventRecord()
        let transport = makeTransport { _ in (Data("not json".utf8), 200, [:]) }
        let result = await transport.push(SyncPushBatch(eventSaves: [record]), accessToken: "tok")
        guard case .unknown = result.failedEvents.first?.error else {
            Issue.record("expected .unknown, got \(String(describing: result.failedEvents.first?.error))")
            return
        }
    }

    // MARK: - HTTP status mapping (401 / 409 / 429 with Retry-After / 5xx)

    @Test func pullMapsHTTPStatusesToTheirTypedTransportErrors() async {
        for (status, expected) in [(401, SyncTransportError.notAuthenticated), (409, .conflict), (500, .serviceUnavailable), (503, .serviceUnavailable)] {
            let transport = makeTransport { _ in (Data(), status, [:]) }
            let page = await transport.pull(cursor: .initial, pageSize: 10, accessToken: "tok")
            #expect(page.error == expected, "status \(status)")
        }
    }

    @Test func pushEventDeletionOnA429SetsRetryNotBeforeFromTheRetryAfterHeaderNeverAsAFailedItem() async throws {
        let eventID = UUID()
        let transport = makeTransport { _ in (Data(), 429, ["Retry-After": "42"]) }
        let before = Date()
        let result = await transport.push(SyncPushBatch(eventDeletions: [eventID]), accessToken: "tok")
        #expect(result.failedEvents.isEmpty) // a rate limit is never reported as a per-item failure
        let retryNotBefore = try #require(result.retryNotBefore)
        #expect(retryNotBefore.timeIntervalSince(before) > 40 && retryNotBefore.timeIntervalSince(before) < 44)
    }

    // MARK: - Pagination, tombstones, quarantine

    @Test func pullReportsHasMorePagesOnlyWhenAPageComesBackFull() async {
        let rows = (0..<5).map { i -> [String: Any] in
            ["id": UUID().uuidString, "title": "E\(i)", "event_type": "generic", "start_date": iso(now),
             "time_zone_identifier": "UTC", "source": "manual", "priority": "medium",
             "server_updated_at": iso(now), "server_seq": i, "is_deleted": false]
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let transport = makeTransport { request in
            request.url?.path == "/rest/v1/sync_events" ? (data, 200, [:]) : (Data("[]".utf8), 200, [:])
        }
        let page = await transport.pull(cursor: .initial, pageSize: 5, accessToken: "tok")
        #expect(page.hasMorePages) // exactly `pageSize` rows came back — must ask for another page
        #expect(page.changedEvents.count == 5)
        #expect(page.nextCursor.events == 5)
    }

    @Test func pullReportsDeletedEventIDsSeparatelyFromChangedEventsForTombstoneRows() async {
        let deletedID = UUID()
        let rows: [[String: Any]] = [[
            "id": deletedID.uuidString, "title": "Gone", "event_type": "generic", "start_date": iso(now),
            "time_zone_identifier": "UTC", "source": "manual", "priority": "medium",
            "server_updated_at": iso(now), "server_seq": 0, "is_deleted": true,
        ]]
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let transport = makeTransport { request in
            request.url?.path == "/rest/v1/sync_events" ? (data, 200, [:]) : (Data("[]".utf8), 200, [:])
        }
        let page = await transport.pull(cursor: .initial, pageSize: 10, accessToken: "tok")
        #expect(page.deletedEventIDs == [deletedID])
        #expect(page.changedEvents.isEmpty)
    }

    @Test func pullQuarantinesARowMissingARequiredFieldRatherThanCrashingOrSilentlyDroppingIt() async {
        let badID = UUID()
        let rows: [[String: Any]] = [[
            "id": badID.uuidString, "event_type": "generic", "start_date": iso(now),
            // "title" deliberately missing — required by `decodeEventGraph`.
            "time_zone_identifier": "UTC", "source": "manual", "priority": "medium",
            "server_updated_at": iso(now), "server_seq": 0, "is_deleted": false,
        ]]
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let transport = makeTransport { request in
            request.url?.path == "/rest/v1/sync_events" ? (data, 200, [:]) : (Data("[]".utf8), 200, [:])
        }
        let page = await transport.pull(cursor: .initial, pageSize: 10, accessToken: "tok")
        #expect(page.quarantinedEventIDs == [badID])
        #expect(page.changedEvents.isEmpty)
    }

    @Test func pullDecodesNullOptionalFieldsWithoutCrashing() async {
        let id = UUID()
        let rows: [[String: Any]] = [[
            "id": id.uuidString, "title": "No Frills", "event_type": "generic", "start_date": iso(now),
            "end_date": NSNull(), "location": NSNull(), "notes": NSNull(),
            "time_zone_identifier": "UTC", "source": "manual", "priority": "medium",
            "server_updated_at": iso(now), "server_seq": 0, "is_deleted": false,
        ]]
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let transport = makeTransport { request in
            request.url?.path == "/rest/v1/sync_events" ? (data, 200, [:]) : (Data("[]".utf8), 200, [:])
        }
        let page = await transport.pull(cursor: .initial, pageSize: 10, accessToken: "tok")
        #expect(page.changedEvents.first?.id == id)
        #expect(page.changedEvents.first?.location == nil)
        #expect(page.changedEvents.first?.notes == nil)
    }

    // MARK: - Cancellation

    @Test func pullReturnsAFailureRatherThanHangingWhenItsTaskIsCancelled() async {
        let transport = makeTransport { _ in
            Thread.sleep(forTimeInterval: 1)
            return (Data("[]".utf8), 200, [:])
        }
        let task = Task { await transport.pull(cursor: .initial, pageSize: 10, accessToken: "tok") }
        task.cancel()
        let page = await task.value
        #expect(page.error != nil) // never silently returns as if the pull actually completed
    }

    // MARK: - Per-item batch results (requirement 4)

    @Test func pushRecurrenceExclusionsAppliesPerItemResultsIncludingAPartialFailure() async {
        let goodID = UUID(), badID = UUID()
        let good = RecurrenceExclusionSyncRecord(id: goodID, seriesID: UUID(), excludedAnchorDate: now)
        let bad = RecurrenceExclusionSyncRecord(id: badID, seriesID: UUID(), excludedAnchorDate: now)
        let transport = makeTransport { _ in
            (Data(#"{"results": [{"id": "\#(goodID.uuidString)", "succeeded": true}, {"id": "\#(badID.uuidString)", "succeeded": false, "error": "push_failed"}]}"#.utf8), 200, [:])
        }
        let result = await transport.push(SyncPushBatch(exclusionSaves: [good, bad]), accessToken: "tok")
        #expect(result.succeededExclusionIDs == [goodID])
        #expect(result.failedExclusions.map(\.id) == [badID])
        #expect(result.failedExclusions.first?.error == .validationFailed)
    }

    @Test func pushNotificationRuleDeletionsAppliesPerItemResults() async {
        let deletedID = UUID(), missingID = UUID()
        let transport = makeTransport { _ in
            (Data(#"{"results": [{"id": "\#(deletedID.uuidString)", "succeeded": true}, {"id": "\#(missingID.uuidString)", "succeeded": false, "error": "not_found"}]}"#.utf8), 200, [:])
        }
        let result = await transport.push(SyncPushBatch(notificationRuleDeletions: [deletedID, missingID]), accessToken: "tok")
        #expect(result.succeededNotificationRuleDeletionIDs == [deletedID])
        #expect(result.failedNotificationRuleDeletions.map(\.id) == [missingID])
    }

    @Test func aBatchWideSuccessStatusIsNeverEnoughOnItsOwnWhenAnItemIsMissingFromTheResults() async {
        // Requirement 4's central claim, verified directly: HTTP 2xx alone must never be read
        // as "every item succeeded" — an item the RPC's own results array is silent about is
        // reported as failed, never silently assumed to have gone through.
        let mentioned = UUID(), unmentioned = UUID()
        let good = RecurrenceExclusionSyncRecord(id: mentioned, seriesID: UUID(), excludedAnchorDate: now)
        let silent = RecurrenceExclusionSyncRecord(id: unmentioned, seriesID: UUID(), excludedAnchorDate: now)
        let transport = makeTransport { _ in (Data(#"{"results": [{"id": "\#(mentioned.uuidString)", "succeeded": true}]}"#.utf8), 200, [:]) }
        let result = await transport.push(SyncPushBatch(exclusionSaves: [good, silent]), accessToken: "tok")
        #expect(result.succeededExclusionIDs == [mentioned])
        #expect(result.failedExclusions.map(\.id) == [unmentioned])
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private extension Data {
    /// `URLRequest.httpBodyStream` (never `.httpBody`) is what a real `URLSession` sometimes
    /// uses for a POST body once it's been handed to a task — drained here so a test can still
    /// inspect exactly what `SupabaseSyncTransport` sent.
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { append(buffer, count: read) } else { break }
        }
    }
}
