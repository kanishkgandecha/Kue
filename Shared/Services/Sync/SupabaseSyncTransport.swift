//
//  SupabaseSyncTransport.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Supabase transport." The one file that talks real HTTP for sync
//  — replaces Kue 2.0 Phase 11's CloudKit-specific `SystemCloudSyncTransport` (removed this
//  phase, docs/33 "CloudKit retirement"). Same "one narrow, DI-seamed file touches the real
//  network" shape `Shared/Services/Accounts/SystemAccountProvider.swift` already establishes —
//  plain `URLSession` against Supabase's own documented REST/RPC endpoints, no third-party SDK,
//  matching this project's zero-dependency footprint. Never owns or refreshes a session itself
//  (requirement M: "avoid duplicated refresh logic") — every call receives an already-valid
//  `accessToken` from `SyncCoordinator`, which obtains it through `AccountCoordinator
//  .refreshIfNeeded()` before ever calling in here.
//
//  Never logs a request/response body, header, or full URL — every error path below maps to a
//  short, typed `SyncTransportError`, never a raw server message that could in principle echo
//  event content back.
//

import Foundation

nonisolated final class SupabaseSyncTransport: SyncTransporting {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    init(configuration: SupabaseConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func ensureReady(accessToken: String) async -> Result<Void, SyncTransportError> {
        // A trivial, zero-row SELECT — confirms the endpoint/key/fresh user token are all valid
        // before this pass attempts any real push/pull work, without touching any real row.
        let request = makeRequest(path: "/rest/v1/sync_events", query: [URLQueryItem(name: "limit", value: "0")], method: "GET", accessToken: accessToken)
        let (_, response) = await perform(request)
        guard let response else { return .failure(.networkFailure) }
        return (200...299).contains(response.statusCode) ? .success(()) : .failure(mapStatus(response.statusCode))
    }

    // MARK: - Push

    func push(_ batch: SyncPushBatch, accessToken: String) async -> SyncPushResult {
        var result = SyncPushResult()

        for record in batch.eventSaves {
            switch await pushEventGraph(record, accessToken: accessToken) {
            case .success(let revision):
                result.succeededEventIDs.insert(record.id)
                result.newRevisionsByEventID[record.id] = revision
            case .conflict:
                result.conflictedEventIDs.insert(record.id)
            case .failure(let error):
                if case .rateLimited(let seconds) = error {
                    result.retryNotBefore = Date().addingTimeInterval(seconds)
                } else {
                    result.failedEvents.append(SyncFailedItem(id: record.id, error: error))
                }
            }
        }

        for eventID in batch.eventDeletions {
            let (data, response) = await performRPC("push_event_deletion", body: ["p_id": eventID.uuidString], accessToken: accessToken)
            if let response, (200...299).contains(response.statusCode) {
                result.succeededEventDeletionIDs.insert(eventID)
            } else if let response {
                let error = mapStatus(response.statusCode)
                if case .rateLimited = error { result.retryNotBefore = retryNotBefore(from: response) }
                else { result.failedEvents.append(SyncFailedItem(id: eventID, error: error)) }
            } else {
                result.failedEvents.append(SyncFailedItem(id: eventID, error: .networkFailure))
            }
            _ = data
        }

        if !batch.exclusionSaves.isEmpty {
            let payload = ["exclusions": batch.exclusionSaves.map(exclusionPayload)]
            let (data, response) = await performRPC("push_recurrence_exclusions", body: payload, accessToken: accessToken)
            if let response, (200...299).contains(response.statusCode), let items = parseItemResults(data) {
                let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for exclusion in batch.exclusionSaves {
                    guard let item = byID[exclusion.id] else {
                        // The RPC's own response never mentioned this item — never assumed to
                        // have succeeded just because the batch-wide call returned 2xx
                        // (requirement G/4: "never treat a batch-wide 2xx as proof every item
                        // succeeded").
                        result.failedExclusions.append(SyncFailedItem(id: exclusion.id, error: .unknown("Missing result.")))
                        continue
                    }
                    if item.succeeded {
                        result.succeededExclusionIDs.insert(exclusion.id)
                    } else {
                        result.failedExclusions.append(SyncFailedItem(id: exclusion.id, error: .validationFailed))
                    }
                }
            } else if let response {
                let error = mapStatus(response.statusCode)
                if case .rateLimited = error { result.retryNotBefore = retryNotBefore(from: response) }
                else { result.failedExclusions = batch.exclusionSaves.map { SyncFailedItem(id: $0.id, error: error) } }
            } else {
                result.failedExclusions = batch.exclusionSaves.map { SyncFailedItem(id: $0.id, error: .networkFailure) }
            }
        }

        if !batch.notificationRuleDeletions.isEmpty {
            let (data, response) = await performRPC(
                "push_notification_rule_deletions",
                body: ["rule_ids": batch.notificationRuleDeletions.map(\.uuidString)],
                accessToken: accessToken
            )
            if let response, (200...299).contains(response.statusCode), let items = parseItemResults(data) {
                let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for ruleID in batch.notificationRuleDeletions {
                    guard let item = byID[ruleID] else {
                        result.failedNotificationRuleDeletions.append(SyncFailedItem(id: ruleID, error: .unknown("Missing result.")))
                        continue
                    }
                    if item.succeeded {
                        result.succeededNotificationRuleDeletionIDs.insert(ruleID)
                    } else {
                        result.failedNotificationRuleDeletions.append(SyncFailedItem(id: ruleID, error: .validationFailed))
                    }
                }
            } else if let response {
                let error = mapStatus(response.statusCode)
                if case .rateLimited = error { result.retryNotBefore = retryNotBefore(from: response) }
                else { result.failedNotificationRuleDeletions = batch.notificationRuleDeletions.map { SyncFailedItem(id: $0, error: error) } }
            } else {
                result.failedNotificationRuleDeletions = batch.notificationRuleDeletions.map { SyncFailedItem(id: $0, error: .networkFailure) }
            }
        }

        return result
    }

    /// One element of `push_recurrence_exclusions`/`push_notification_rule_deletions`'s own
    /// `{"results": [{"id", "succeeded", "error"?}, ...]}` response shape (Phase 5 correction,
    /// requirement G/4) — every item in a batch RPC gets its own truthful pass/fail, never a
    /// bare aggregate count a client would have to blindly trust for every id it sent.
    private struct BatchItemResult {
        let id: UUID
        let succeeded: Bool
    }

    private func parseItemResults(_ data: Data?) -> [BatchItemResult]? {
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["results"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap { row in
            guard let idString = row["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
            return BatchItemResult(id: id, succeeded: row["succeeded"] as? Bool ?? false)
        }
    }

    private enum PushOutcome {
        case success(revision: Int64)
        case conflict
        case failure(SyncTransportError)
    }

    private func pushEventGraph(_ record: EventSyncRecord, accessToken: String) async -> PushOutcome {
        var payload = eventGraphPayload(record)
        payload["expectedRevision"] = record.revision
        let (data, response) = await performRPC("push_event_graph", body: ["payload": payload], accessToken: accessToken)
        guard let response else { return .failure(.networkFailure) }
        guard (200...299).contains(response.statusCode) else {
            let error = mapStatus(response.statusCode)
            return .failure(error)
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unknown("Malformed push response."))
        }
        if let conflict = json["conflict"] as? Bool, conflict { return .conflict }
        if json["error"] != nil { return .failure(.validationFailed) }
        if let revision = json["revision"] as? NSNumber { return .success(revision: revision.int64Value) }
        return .failure(.unknown("Missing revision in push response."))
    }

    // MARK: - Pull

    func pull(cursor: SyncCursor, pageSize: Int, accessToken: String) async -> SyncPullPage {
        async let eventsResult = fetchEvents(after: cursor.events, limit: pageSize, accessToken: accessToken)
        async let exclusionsResult = fetchExclusions(after: cursor.exclusions, limit: pageSize, accessToken: accessToken)

        let (eventRows, eventsError) = await eventsResult
        let (exclusionRows, exclusionsError) = await exclusionsResult
        if let error = eventsError ?? exclusionsError {
            return SyncPullPage(nextCursor: cursor, error: error)
        }

        var changedEvents: [EventSyncRecord] = []
        var deletedEventIDs: [UUID] = []
        var quarantined: [UUID] = []
        var childrenError: SyncTransportError?

        let liveEventRows = eventRows.filter { !($0["is_deleted"] as? Bool ?? false) }
        let liveEventIDs = liveEventRows.compactMap { $0["id"] as? String }
        let (taskRows, scheduleRows, ruleRows, fetchError) = await fetchChildren(forEventIDs: liveEventIDs, accessToken: accessToken)
        childrenError = fetchError

        for row in eventRows {
            guard let idString = row["id"] as? String, let id = UUID(uuidString: idString) else { continue }
            if row["is_deleted"] as? Bool == true {
                deletedEventIDs.append(id)
                continue
            }
            if let record = decodeEventGraph(eventRow: row, taskRows: taskRows, scheduleRows: scheduleRows, ruleRows: ruleRows) {
                changedEvents.append(record)
            } else {
                quarantined.append(id)
            }
        }

        if let childrenError { return SyncPullPage(nextCursor: cursor, error: childrenError) }

        let changedExclusions = exclusionRows.compactMap(decodeExclusion)

        let maxEventSeq = eventRows.compactMap { ($0["server_seq"] as? NSNumber)?.int64Value }.max()
        let maxExclusionSeq = exclusionRows.compactMap { ($0["server_seq"] as? NSNumber)?.int64Value }.max()
        let nextCursor = SyncCursor(
            events: max(cursor.events, (maxEventSeq ?? -1) + 1),
            exclusions: max(cursor.exclusions, (maxExclusionSeq ?? -1) + 1)
        )
        let hasMore = eventRows.count == pageSize || exclusionRows.count == pageSize

        return SyncPullPage(
            changedEvents: changedEvents, deletedEventIDs: deletedEventIDs, changedExclusions: changedExclusions,
            quarantinedEventIDs: quarantined, nextCursor: nextCursor, hasMorePages: hasMore
        )
    }

    private func fetchEvents(after seq: Int64, limit: Int, accessToken: String) async -> ([[String: Any]], SyncTransportError?) {
        await fetchRows(
            path: "/rest/v1/sync_events",
            query: [
                URLQueryItem(name: "server_seq", value: "gte.\(seq)"),
                URLQueryItem(name: "order", value: "server_seq.asc"),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ],
            accessToken: accessToken
        )
    }

    private func fetchExclusions(after seq: Int64, limit: Int, accessToken: String) async -> ([[String: Any]], SyncTransportError?) {
        await fetchRows(
            path: "/rest/v1/sync_recurrence_exclusions",
            query: [
                URLQueryItem(name: "server_seq", value: "gte.\(seq)"),
                URLQueryItem(name: "order", value: "server_seq.asc"),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ],
            accessToken: accessToken
        )
    }

    private func fetchChildren(forEventIDs eventIDs: [String], accessToken: String) async -> ([[String: Any]], [[String: Any]], [[String: Any]], SyncTransportError?) {
        guard !eventIDs.isEmpty else { return ([], [], [], nil) }
        let inList = "(\(eventIDs.joined(separator: ",")))"
        async let tasks = fetchRows(path: "/rest/v1/sync_tasks", query: [URLQueryItem(name: "event_id", value: "in.\(inList)"), URLQueryItem(name: "is_deleted", value: "eq.false")], accessToken: accessToken)
        async let schedules = fetchRows(path: "/rest/v1/sync_schedules", query: [URLQueryItem(name: "event_id", value: "in.\(inList)"), URLQueryItem(name: "is_deleted", value: "eq.false")], accessToken: accessToken)
        async let rules = fetchRows(path: "/rest/v1/sync_notification_rules", query: [URLQueryItem(name: "event_id", value: "in.\(inList)"), URLQueryItem(name: "is_deleted", value: "eq.false")], accessToken: accessToken)
        // Task-owned rules need a second query — task ids aren't known until the task fetch above resolves.
        let (taskRows, taskError) = await tasks
        let (scheduleRows, scheduleError) = await schedules
        let (eventRuleRows, ruleError) = await rules
        let taskIDs = taskRows.compactMap { $0["id"] as? String }
        var taskRuleRows: [[String: Any]] = []
        var taskRuleError: SyncTransportError?
        if !taskIDs.isEmpty {
            let taskInList = "(\(taskIDs.joined(separator: ",")))"
            (taskRuleRows, taskRuleError) = await fetchRows(path: "/rest/v1/sync_notification_rules", query: [URLQueryItem(name: "task_id", value: "in.\(taskInList)"), URLQueryItem(name: "is_deleted", value: "eq.false")], accessToken: accessToken)
        }
        return (taskRows, scheduleRows, eventRuleRows + taskRuleRows, taskError ?? scheduleError ?? ruleError ?? taskRuleError)
    }

    func resetLocalAccountState() async {
        // Nothing server-side to reset for a REST/PostgREST transport (no persisted engine
        // state to quarantine, unlike CloudKit's own `CKSyncEngine.State.Serialization`) — the
        // account-switch guard lives entirely in `SyncCoordinator`'s own local cursor/outbox
        // state, keyed per account (`SyncStatePersisting`'s own header).
    }

    // MARK: - Wire-shape encoding

    private func eventGraphPayload(_ record: EventSyncRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "id": record.id.uuidString, "title": record.title, "eventType": record.eventType,
            "startDate": iso(record.startDate), "estimatedDurationMinutes": record.estimatedDurationMinutes,
            "isAllDay": record.isAllDay, "timeZoneIdentifier": record.timeZoneIdentifier,
            "source": record.source, "priority": record.priority, "isCancelled": record.isCancelled,
            "isManuallyCompleted": record.isManuallyCompleted, "isRecurrenceException": record.isRecurrenceException,
            "isSkipped": record.isSkipped, "createdAt": iso(record.createdAt), "clientUpdatedAt": iso(record.updatedAt),
            "clientMutationID": record.clientMutationID.uuidString,
            "tasks": record.tasks.map(taskPayload),
            "notificationRules": record.notificationRules.map(rulePayload),
        ]
        payload["endDate"] = record.endDate.map(iso)
        payload["location"] = record.location
        payload["notes"] = record.notes
        payload["cancelledAt"] = record.cancelledAt.map(iso)
        payload["manuallyCompletedAt"] = record.manuallyCompletedAt.map(iso)
        payload["seriesID"] = record.seriesID?.uuidString
        payload["recurrenceAnchorDate"] = record.recurrenceAnchorDate.map(iso)
        payload["skippedAt"] = record.skippedAt.map(iso)
        if let recurrence = record.recurrence {
            payload["recurrenceFrequency"] = recurrence.frequency
            payload["recurrenceInterval"] = recurrence.interval
            payload["recurrenceEndKind"] = recurrence.endKind
            payload["recurrenceEndDate"] = recurrence.endDate.map(iso)
            payload["recurrenceEndOccurrenceCount"] = recurrence.endOccurrenceCount
        }
        if let schedule = record.schedule {
            payload["schedule"] = [
                "id": schedule.id.uuidString, "templateType": schedule.templateType,
                "isCustom": schedule.isCustom, "generatedAt": iso(schedule.generatedAt),
                // `ScheduleRulePayload.offset` is a `DateComponents` — not something worth
                // hand-picking fields for (and a real bug this file's own review caught: an
                // earlier draft only carried `taskTitle`/`isTimeSensitive`, silently dropping
                // `offset` on every round-trip). Round-tripped through `Codable` directly
                // instead, so the JSONB column always carries the exact same shape
                // `KueSchedule.rulesData`'s own local JSON encoding already uses.
                "rules": encodeAsJSONObject(schedule.rules) ?? [],
            ]
        }
        return payload
    }

    /// Encodes any `Codable` value to a plain `[String: Any]`/`[Any]`-compatible JSON object —
    /// the shape `JSONSerialization.data(withJSONObject:)` (used to build the RPC's own request
    /// body) needs, since it can't take a `Codable` value directly.
    private func encodeAsJSONObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func taskPayload(_ task: TaskSyncPayload) -> [String: Any] {
        [
            "id": task.id.uuidString, "title": task.title, "dueDate": iso(task.dueDate),
            "isCompleted": task.isCompleted, "completedAt": task.completedAt.map(iso) as Any,
            "offsetLabel": task.offsetLabel, "sortOrder": task.sortOrder,
        ]
    }

    private func rulePayload(_ rule: NotificationRuleSyncPayload) -> [String: Any] {
        var payload: [String: Any] = [
            "id": rule.id.uuidString, "anchor": rule.anchor, "offsetDirection": rule.offsetDirection,
            "offsetQuantity": rule.offsetQuantity, "offsetUnit": rule.offsetUnit, "isEnabled": rule.isEnabled,
            "sound": rule.sound, "interruptionPreference": rule.interruptionPreference,
            "sortOrder": rule.sortOrder, "createdAt": iso(rule.createdAt), "clientUpdatedAt": iso(rule.updatedAt),
        ]
        payload["taskID"] = rule.taskID?.uuidString
        payload["absoluteDate"] = rule.absoluteDate.map(iso)
        payload["customTitle"] = rule.customTitle
        payload["customBody"] = rule.customBody
        payload["snoozeMinutes"] = rule.snoozeMinutes
        return payload
    }

    private func exclusionPayload(_ record: RecurrenceExclusionSyncRecord) -> [String: Any] {
        [
            "id": record.id.uuidString, "seriesID": record.seriesID.uuidString,
            "excludedAnchorDate": iso(record.excludedAnchorDate), "clientMutationID": record.clientMutationID.uuidString,
        ]
    }

    private func decodeEventGraph(eventRow: [String: Any], taskRows: [[String: Any]], scheduleRows: [[String: Any]], ruleRows: [[String: Any]]) -> EventSyncRecord? {
        guard
            let idString = eventRow["id"] as? String, let id = UUID(uuidString: idString),
            let title = eventRow["title"] as? String,
            let eventType = eventRow["event_type"] as? String,
            let startDateString = eventRow["start_date"] as? String, let startDate = parseDate(startDateString),
            let timeZoneIdentifier = eventRow["time_zone_identifier"] as? String,
            let source = eventRow["source"] as? String,
            let priority = eventRow["priority"] as? String,
            let serverUpdatedAtString = eventRow["server_updated_at"] as? String, let serverUpdatedAt = parseDate(serverUpdatedAtString)
        else { return nil }

        let ownTasks = taskRows.filter { ($0["event_id"] as? String) == idString }
        let taskPayloads = ownTasks.compactMap(decodeTask)
        let taskIDStrings = Set(ownTasks.compactMap { $0["id"] as? String })

        var recurrence: RecurrenceRulePayload?
        if let frequency = eventRow["recurrence_frequency"] as? String, let interval = (eventRow["recurrence_interval"] as? NSNumber)?.intValue {
            recurrence = RecurrenceRulePayload(
                frequency: frequency, interval: interval,
                endKind: eventRow["recurrence_end_kind"] as? String ?? "never",
                endDate: (eventRow["recurrence_end_date"] as? String).flatMap(parseDate),
                endOccurrenceCount: (eventRow["recurrence_end_occurrence_count"] as? NSNumber)?.intValue
            )
        }

        var schedule: SchedulePayload?
        if let scheduleRow = scheduleRows.first(where: { ($0["event_id"] as? String) == idString }) {
            schedule = decodeSchedule(scheduleRow)
        }

        let ownRules = ruleRows.filter { ($0["event_id"] as? String) == idString }
        let taskRules = ruleRows.filter { row in (row["task_id"] as? String).map(taskIDStrings.contains) ?? false }
        let notificationRules = (ownRules + taskRules).compactMap(decodeRule)

        return EventSyncRecord(
            id: id, title: title, eventType: eventType, startDate: startDate,
            endDate: (eventRow["end_date"] as? String).flatMap(parseDate),
            estimatedDurationMinutes: (eventRow["estimated_duration_minutes"] as? NSNumber)?.intValue ?? 0,
            isAllDay: eventRow["is_all_day"] as? Bool ?? false, timeZoneIdentifier: timeZoneIdentifier,
            location: eventRow["location"] as? String, notes: eventRow["notes"] as? String,
            source: source, priority: priority,
            isCancelled: eventRow["is_cancelled"] as? Bool ?? false,
            cancelledAt: (eventRow["cancelled_at"] as? String).flatMap(parseDate),
            isManuallyCompleted: eventRow["is_manually_completed"] as? Bool ?? false,
            manuallyCompletedAt: (eventRow["manually_completed_at"] as? String).flatMap(parseDate),
            recurrence: recurrence,
            seriesID: (eventRow["series_id"] as? String).flatMap(UUID.init(uuidString:)),
            recurrenceAnchorDate: (eventRow["recurrence_anchor_date"] as? String).flatMap(parseDate),
            isRecurrenceException: eventRow["is_recurrence_exception"] as? Bool ?? false,
            isSkipped: eventRow["is_skipped"] as? Bool ?? false,
            skippedAt: (eventRow["skipped_at"] as? String).flatMap(parseDate),
            tasks: taskPayloads, schedule: schedule, widgetConfiguration: nil,
            notificationRules: notificationRules,
            createdAt: (eventRow["created_at"] as? String).flatMap(parseDate) ?? startDate,
            updatedAt: serverUpdatedAt,
            revision: (eventRow["revision"] as? NSNumber)?.int64Value ?? 0,
            clientMutationID: (eventRow["client_mutation_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        )
    }

    private func decodeTask(_ row: [String: Any]) -> TaskSyncPayload? {
        guard
            let idString = row["id"] as? String, let id = UUID(uuidString: idString),
            let title = row["title"] as? String,
            let dueDateString = row["due_date"] as? String, let dueDate = parseDate(dueDateString)
        else { return nil }
        return TaskSyncPayload(
            id: id, title: title, dueDate: dueDate, isCompleted: row["is_completed"] as? Bool ?? false,
            completedAt: (row["completed_at"] as? String).flatMap(parseDate),
            offsetLabel: row["offset_label"] as? String ?? "", sortOrder: (row["sort_order"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func decodeSchedule(_ row: [String: Any]) -> SchedulePayload? {
        guard
            let idString = row["id"] as? String, let id = UUID(uuidString: idString),
            let templateType = row["template_type"] as? String
        else { return nil }
        // The inverse of `encodeAsJSONObject` above — re-serialize the already-parsed JSON
        // value back to `Data` so `JSONDecoder` can decode it through `ScheduleRulePayload`'s
        // own `Codable` conformance (including `DateComponents`) rather than hand-picking
        // fields, which would silently drop `offset` exactly like the push-side bug this same
        // review found and fixed.
        var rules: [ScheduleRulePayload] = []
        if let rulesJSON = row["rules"], JSONSerialization.isValidJSONObject(rulesJSON) || rulesJSON is [Any],
           let data = try? JSONSerialization.data(withJSONObject: rulesJSON) {
            rules = (try? JSONDecoder().decode([ScheduleRulePayload].self, from: data)) ?? []
        }
        return SchedulePayload(
            id: id, templateType: templateType, rules: rules, isCustom: row["is_custom"] as? Bool ?? false,
            generatedAt: (row["generated_at"] as? String).flatMap(parseDate) ?? .now
        )
    }

    private func decodeRule(_ row: [String: Any]) -> NotificationRuleSyncPayload? {
        guard
            let idString = row["id"] as? String, let id = UUID(uuidString: idString),
            let anchor = row["anchor"] as? String,
            let offsetDirection = row["offset_direction"] as? String,
            let offsetUnit = row["offset_unit"] as? String,
            let createdAtString = row["created_at"] as? String, let createdAt = parseDate(createdAtString)
        else { return nil }
        return NotificationRuleSyncPayload(
            id: id, taskID: (row["task_id"] as? String).flatMap(UUID.init(uuidString:)),
            anchor: anchor, offsetDirection: offsetDirection,
            offsetQuantity: (row["offset_quantity"] as? NSNumber)?.intValue ?? 0, offsetUnit: offsetUnit,
            absoluteDate: (row["absolute_date"] as? String).flatMap(parseDate),
            isEnabled: row["is_enabled"] as? Bool ?? true,
            customTitle: row["custom_title"] as? String, customBody: row["custom_body"] as? String,
            sound: row["sound"] as? String ?? "defaultSound",
            interruptionPreference: row["interruption_preference"] as? String ?? "active",
            snoozeMinutes: (row["snooze_minutes"] as? NSNumber)?.intValue,
            sortOrder: (row["sort_order"] as? NSNumber)?.intValue ?? 0,
            createdAt: createdAt,
            updatedAt: (row["server_updated_at"] as? String).flatMap(parseDate) ?? createdAt
        )
    }

    private func decodeExclusion(_ row: [String: Any]) -> RecurrenceExclusionSyncRecord? {
        guard
            let idString = row["id"] as? String, let id = UUID(uuidString: idString),
            let seriesIDString = row["series_id"] as? String, let seriesID = UUID(uuidString: seriesIDString),
            let excludedAnchorDateString = row["excluded_anchor_date"] as? String, let excludedAnchorDate = parseDate(excludedAnchorDateString)
        else { return nil }
        return RecurrenceExclusionSyncRecord(id: id, seriesID: seriesID, excludedAnchorDate: excludedAnchorDate)
    }

    // MARK: - HTTP plumbing (mirrors SystemAccountProvider's own shape)

    private func fetchRows(path: String, query: [URLQueryItem], accessToken: String) async -> ([[String: Any]], SyncTransportError?) {
        let request = makeRequest(path: path, query: query, method: "GET", accessToken: accessToken)
        let (data, response) = await perform(request)
        guard let response else { return ([], .networkFailure) }
        guard (200...299).contains(response.statusCode) else { return ([], mapStatus(response.statusCode)) }
        guard let data, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], nil) }
        return (rows, nil)
    }

    private func performRPC(_ name: String, body: [String: Any], accessToken: String) async -> (Data?, HTTPURLResponse?) {
        var request = makeRequest(path: "/rest/v1/rpc/\(name)", query: [], method: "POST", accessToken: accessToken)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await perform(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem], method: String, accessToken: String?) -> URLRequest {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? configuration.url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        return request
    }

    private var anonAccessToken: String { "Bearer \(configuration.anonKey)" }

    private func perform(_ request: URLRequest) async -> (Data?, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            return (nil, nil)
        }
    }

    private func retryNotBefore(from response: HTTPURLResponse) -> Date {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
            return Date().addingTimeInterval(seconds)
        }
        return Date().addingTimeInterval(30)
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

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func parseDate(_ string: String) -> Date? {
        SupabaseSyncTransport.flexibleFormatter.date(from: string) ?? SupabaseSyncTransport.plainFormatter.date(from: string)
    }
    private static let flexibleFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
}
