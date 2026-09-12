//
//  SupabaseStatisticsTransport.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Transport and synchronization." Plain `URLSession` against
//  Supabase's own PostgREST REST endpoint for `statistics_aggregates` — no RPC needed at all
//  (unlike Phase 5's event-graph push), since a plain upsert is always a sound, total
//  replacement of one small, non-conflicting weekly summary row. No service-role key anywhere
//  in this file or any Apple target — only the publishable/anon key plus whatever
//  already-refreshed user access token the caller hands in (requirement M).
//
//  ponytail: `makeRequest`/`perform`/`mapStatus` below are a near-duplicate of
//  `SupabaseSyncTransport`'s own identical trio (Shared/Services/Sync/) rather than factored
//  into one shared helper — deliberately, to avoid touching that already-shipped, already-
//  tested Phase 5 file for a three-function, ~25-line seam. Extract a shared
//  `SupabasePostgRESTClient` if a third transport ever needs the exact same plumbing.
//
//  Never logs a request/response body, header, or full URL — every error path maps to
//  `SyncTransportError`, never a raw server message.
//

import Foundation

nonisolated final class SupabaseStatisticsTransport: StatisticsTransporting {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    init(configuration: SupabaseConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func upload(_ payload: StatisticsAggregatePayload, accessToken: String) async -> Result<Void, SyncTransportError> {
        var request = makeRequest(
            path: "/rest/v1/statistics_aggregates",
            query: [URLQueryItem(name: "on_conflict", value: "user_id,bucket_start")],
            method: "POST", accessToken: accessToken
        )
        // Requirement D: "idempotent upsert behavior" — PostgREST's own merge-duplicates
        // resolution against the table's `(user_id, bucket_start)` primary key, never a second
        // row for the same account/week. `return=minimal`: the response body is never needed
        // and never inspected, so it's never requested.
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONEncoder().encode(payload)
        let (_, response) = await perform(request)
        guard let response else { return .failure(.networkFailure) }
        return (200...299).contains(response.statusCode) ? .success(()) : .failure(mapStatus(response.statusCode))
    }

    func fetchRecentAggregates(accessToken: String, userID: UUID) async -> Result<[StatisticsAggregatePayload], SyncTransportError> {
        let request = makeRequest(
            path: "/rest/v1/statistics_aggregates",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)"),
                URLQueryItem(name: "order", value: "bucket_start.desc"),
            ],
            method: "GET", accessToken: accessToken
        )
        let (data, response) = await perform(request)
        guard let response else { return .failure(.networkFailure) }
        guard (200...299).contains(response.statusCode) else { return .failure(mapStatus(response.statusCode)) }
        guard let data, let rows = try? JSONDecoder().decode([StatisticsAggregatePayload].self, from: data) else {
            return .failure(.unknown("Malformed response."))
        }
        return .success(rows)
    }

    func deleteAll(accessToken: String, userID: UUID) async -> Result<Void, SyncTransportError> {
        let request = makeRequest(
            path: "/rest/v1/statistics_aggregates",
            query: [URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)")],
            method: "DELETE", accessToken: accessToken
        )
        let (_, response) = await perform(request)
        guard let response else { return .failure(.networkFailure) }
        return (200...299).contains(response.statusCode) ? .success(()) : .failure(mapStatus(response.statusCode))
    }

    // MARK: - HTTP plumbing (mirrors SupabaseSyncTransport's own shape — see this file's header)

    private func makeRequest(path: String, query: [URLQueryItem], method: String, accessToken: String) -> URLRequest {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? configuration.url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        return request
    }

    private func perform(_ request: URLRequest) async -> (Data?, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            return (nil, nil)
        }
    }

    private func mapStatus(_ statusCode: Int) -> SyncTransportError {
        switch statusCode {
        case 401: return .notAuthenticated
        case 403: return .permissionFailure
        case 404: return .unknown("Not found.")
        case 409: return .conflict
        case 422: return .validationFailed
        case 429: return .rateLimited(retryAfterSeconds: 30)
        case 500...599: return .serviceUnavailable
        default: return .unknown("Unexpected response (\(statusCode)).")
        }
    }
}
