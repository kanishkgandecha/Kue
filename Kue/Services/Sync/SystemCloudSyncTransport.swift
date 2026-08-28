//
//  SystemCloudSyncTransport.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26-icloud-cloudkit-sync.md "A./N." The one file that actually
//  drives `CKSyncEngine` against Kue's private custom zone. App-only, imports CloudKit —
//  nothing in `Shared/` does (docs/26 "R.": "The System implementation should be the only
//  layer importing CloudKit where practical"). `CKSyncEngine`'s own delegate callbacks are
//  event-driven, not request/response, so this bridges them into the simple async
//  `CloudSyncTransporting` contract `SyncCoordinator` drives via `CheckedContinuation` —
//  one in-flight send/fetch at a time, which matches Kue's realistic sync volume (a personal
//  event planner, never a high-throughput target) and keeps this bridge simple and correct
//  rather than building a general-purpose concurrent-operation queue nothing here needs.
//
//  **Never live-tested in this environment** — the signed-in developer account is a free
//  Personal Team, which Apple does not allow to provision the iCloud/CloudKit capability
//  (confirmed via a real `xcodebuild -allowProvisioningUpdates` attempt against a device
//  destination — see docs/26 "V."). Every line below is written against CKSyncEngine's real,
//  documented API surface, but has only ever been exercised via `FakeCloudSyncTransport` in
//  tests, never a real `CKContainer`.
//

import CloudKit
import Foundation

/// An `actor`, not `@MainActor` — `CKSyncEngineDelegate`'s callbacks arrive on whatever
/// thread CloudKit chooses, and this class never touches `ModelContext`/SwiftUI itself (only
/// `SyncCoordinator`, `@MainActor`, does — see that file's own header), so actor isolation is
/// the correct, minimal-friction fit here rather than forcing every delegate callback to hop
/// to the main actor for no reason.
actor SystemCloudSyncTransport: CloudSyncTransporting, CKSyncEngineDelegate {
    static let shared = SystemCloudSyncTransport()

    private let container: CKContainer
    private lazy var database = container.privateCloudDatabase
    private let zoneID: CKRecordZone.ID

    private var syncEngine: CKSyncEngine?
    private var pendingSendContinuation: CheckedContinuation<SyncSendResult, Never>?
    private var pendingFetchContinuation: CheckedContinuation<SyncFetchResult, Never>?
    private var accumulatedSendResult = SyncSendResult()
    private var accumulatedFetchResult = SyncFetchResult()

    init(container: CKContainer = CKContainer(identifier: CloudKitContainerIdentifier.value)) {
        self.container = container
        self.zoneID = CKRecordZone.ID(zoneName: SyncRecordFormat.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func engine() -> CKSyncEngine {
        if let syncEngine { return syncEngine }
        let stateData = SystemCloudSyncStateStore.shared.load().engineStateData
        let serialization = stateData.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.syncEngine = engine
        return engine
    }

    func ensureZoneExists() async -> Result<Void, SyncTransportError> {
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            return .success(())
        } catch let error as CKError where error.code == .zoneNotFound {
            return .failure(.zoneNotFound)
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    func send(
        eventSaves: [EventSyncRecord],
        eventDeletions: [UUID],
        exclusionSaves: [RecurrenceExclusionSyncRecord],
        exclusionDeletions: [UUID]
    ) async -> SyncSendResult {
        guard !eventSaves.isEmpty || !eventDeletions.isEmpty || !exclusionSaves.isEmpty || !exclusionDeletions.isEmpty else {
            return SyncSendResult()
        }
        let engine = engine()
        var recordIDsToSave: [CKRecord.ID] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for record in eventSaves {
            let ckRecord = Self.makeCKRecord(for: record, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(ckRecord.recordID)])
            pendingCKRecordsToSave[ckRecord.recordID] = ckRecord
            recordIDsToSave.append(ckRecord.recordID)
        }
        for id in eventDeletions {
            let recordID = Self.recordID(eventID: id, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            recordIDsToDelete.append(recordID)
        }
        for record in exclusionSaves {
            let ckRecord = Self.makeCKRecord(for: record, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(ckRecord.recordID)])
            pendingCKRecordsToSave[ckRecord.recordID] = ckRecord
            recordIDsToSave.append(ckRecord.recordID)
        }
        for id in exclusionDeletions {
            let recordID = Self.recordID(exclusionID: id, zoneID: zoneID)
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            recordIDsToDelete.append(recordID)
        }

        accumulatedSendResult = SyncSendResult()
        return await withCheckedContinuation { continuation in
            pendingSendContinuation = continuation
            Task { try? await engine.sendChanges() }
        }
    }

    func fetchChanges() async -> SyncFetchResult {
        accumulatedFetchResult = SyncFetchResult()
        return await withCheckedContinuation { continuation in
            pendingFetchContinuation = continuation
            Task { try? await engine().fetchChanges() }
        }
    }

    func resetEngineState() async {
        syncEngine = nil
        pendingCKRecordsToSave = [:]
        var state = SystemCloudSyncStateStore.shared.load()
        state.engineStateData = nil
        SystemCloudSyncStateStore.shared.save(state)
    }

    /// Held only long enough for `nextRecordZoneChangeBatch(_:syncEngine:)` to consume — the
    /// engine asks for a batch *after* `state.add(pendingRecordZoneChanges:)` above, not at
    /// the moment of the call, so the actual `CKRecord` content has to be looked up then.
    private var pendingCKRecordsToSave: [CKRecord.ID: CKRecord] = [:]

    // MARK: - Record <-> CKRecord (docs/26 "R.": the CloudKit-touching half of `CloudRecordEncoding`)

    private static func recordID(eventID: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: eventID.uuidString, zoneID: zoneID)
    }
    private static func recordID(exclusionID: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "exclusion-\(exclusionID.uuidString)", zoneID: zoneID)
    }

    /// docs/26 "C.": "Use existing stable UUIDs as CloudKit record names" — never a second
    /// identity. The whole payload travels as one opaque JSON `Data` field; CloudKit itself
    /// never needs to query into individual fields (docs/26 "C.": "no collaboration/shared
    /// database in this phase" — no server-side query surface Kue relies on).
    private static func makeCKRecord(for record: EventSyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let ckRecord = CKRecord(recordType: SyncRecordFormat.RecordType.event, recordID: recordID(eventID: record.id, zoneID: zoneID))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        ckRecord["payload"] = (try? encoder.encode(record)) as CKRecordValue?
        ckRecord["recordFormatVersion"] = record.recordFormatVersion as CKRecordValue
        ckRecord["updatedAt"] = record.updatedAt as CKRecordValue
        return ckRecord
    }

    private static func makeCKRecord(for record: RecurrenceExclusionSyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let ckRecord = CKRecord(recordType: SyncRecordFormat.RecordType.recurrenceExclusion, recordID: recordID(exclusionID: record.id, zoneID: zoneID))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        ckRecord["payload"] = (try? encoder.encode(record)) as CKRecordValue?
        ckRecord["recordFormatVersion"] = record.recordFormatVersion as CKRecordValue
        return ckRecord
    }

    private static func decodeEvent(from ckRecord: CKRecord) -> Result<EventSyncRecord, SyncTransportError> {
        guard let data = ckRecord["payload"] as? Data else { return .failure(.corruptRecord) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return .success(try decoder.decode(EventSyncRecord.self, from: data))
        } catch SyncDecodingError.unsupportedFutureVersion {
            return .failure(.unsupportedFutureRecordFormat)
        } catch {
            return .failure(.corruptRecord)
        }
    }

    private static func decodeExclusion(from ckRecord: CKRecord) -> Result<RecurrenceExclusionSyncRecord, SyncTransportError> {
        guard let data = ckRecord["payload"] as? Data else { return .failure(.corruptRecord) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return .success(try decoder.decode(RecurrenceExclusionSyncRecord.self, from: data))
        } catch SyncDecodingError.unsupportedFutureVersion {
            return .failure(.unsupportedFutureRecordFormat)
        } catch {
            return .failure(.corruptRecord)
        }
    }

    static func mapError(_ error: Error) -> SyncTransportError {
        guard let ckError = error as? CKError else { return .unknown(String(describing: error)) }
        switch ckError.code {
        case .notAuthenticated: return .notAuthenticated
        case .accountTemporarilyUnavailable: return .accountTemporarilyUnavailable
        case .networkUnavailable: return .networkUnavailable
        case .networkFailure: return .networkFailure
        case .serviceUnavailable: return .serviceUnavailable
        case .requestRateLimited:
            let seconds = (ckError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? 30
            return .rateLimited(retryAfterSeconds: seconds)
        case .zoneBusy: return .zoneBusy
        case .serverRecordChanged: return .serverRecordChanged
        case .quotaExceeded: return .quotaExceeded
        case .permissionFailure: return .permissionFailure
        case .unknownItem: return .unknownItem
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .changeTokenExpired: return .changeTokenExpired
        case .partialFailure: return .unknown("partialFailure")
        default: return .unknown(ckError.localizedDescription)
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SystemCloudSyncTransport {
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Snapshotted before the closure below — `RecordZoneChangeBatch`'s own
        // `recordProvider` parameter is a plain synchronous closure, which can't `await` back
        // into this actor's isolated state, so the lookup table it needs has to already be a
        // plain (non-isolated) local value by the time the closure runs.
        let snapshot = pendingCKRecordsToSave
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: syncEngine.state.pendingRecordZoneChanges) { recordID in
            snapshot[recordID]
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            if let data = try? JSONEncoder().encode(stateUpdate.stateSerialization) {
                var state = SystemCloudSyncStateStore.shared.load()
                state.engineStateData = data
                SystemCloudSyncStateStore.shared.save(state)
            }

        case .sentRecordZoneChanges(let event):
            for saved in event.savedRecords {
                if saved.recordType == SyncRecordFormat.RecordType.event {
                    accumulatedSendResult.succeededEventIDs.insert(UUID(uuidString: saved.recordID.recordName) ?? UUID())
                } else if saved.recordType == SyncRecordFormat.RecordType.recurrenceExclusion {
                    if let id = Self.exclusionID(from: saved.recordID) {
                        accumulatedSendResult.succeededExclusionIDs.insert(id)
                    }
                }
                pendingCKRecordsToSave.removeValue(forKey: saved.recordID)
            }
            for deleted in event.deletedRecordIDs {
                if let id = UUID(uuidString: deleted.recordName) {
                    accumulatedSendResult.succeededEventDeletionIDs.insert(id)
                } else if let id = Self.exclusionID(from: deleted) {
                    accumulatedSendResult.succeededExclusionDeletionIDs.insert(id)
                }
            }
            for failed in event.failedRecordSaves {
                let mapped = Self.mapError(failed.error)
                if let id = UUID(uuidString: failed.record.recordID.recordName) {
                    accumulatedSendResult.failedEvents.append(SyncFailedItem(id: id, error: mapped))
                } else if let id = Self.exclusionID(from: failed.record.recordID) {
                    accumulatedSendResult.failedExclusions.append(SyncFailedItem(id: id, error: mapped))
                }
                if case .rateLimited = mapped, let retryAfter = failed.error.retryAfterSeconds {
                    accumulatedSendResult.retryNotBefore = Date().addingTimeInterval(retryAfter)
                }
            }
            pendingSendContinuation?.resume(returning: accumulatedSendResult)
            pendingSendContinuation = nil

        case .fetchedRecordZoneChanges(let event):
            for modification in event.modifications {
                let ckRecord = modification.record
                if ckRecord.recordType == SyncRecordFormat.RecordType.event {
                    switch Self.decodeEvent(from: ckRecord) {
                    case .success(let record): accumulatedFetchResult.changedEvents.append(record)
                    case .failure(.unsupportedFutureRecordFormat):
                        if let id = UUID(uuidString: ckRecord.recordID.recordName) {
                            accumulatedFetchResult.quarantinedEventIDs.append(id)
                        }
                    case .failure: break // corrupt — silently skipped, never crashes or partially applies (docs/26 "N.")
                    }
                } else if ckRecord.recordType == SyncRecordFormat.RecordType.recurrenceExclusion {
                    switch Self.decodeExclusion(from: ckRecord) {
                    case .success(let record): accumulatedFetchResult.changedExclusions.append(record)
                    case .failure(.unsupportedFutureRecordFormat):
                        if let id = Self.exclusionID(from: ckRecord.recordID) {
                            accumulatedFetchResult.quarantinedExclusionIDs.append(id)
                        }
                    case .failure: break
                    }
                }
            }
            for deletion in event.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    accumulatedFetchResult.deletedEventIDs.append(id)
                } else if let id = Self.exclusionID(from: deletion.recordID) {
                    accumulatedFetchResult.deletedExclusionIDs.append(id)
                }
            }

        case .fetchedDatabaseChanges, .willFetchChanges, .willSendChanges:
            break

        case .didFetchChanges:
            pendingFetchContinuation?.resume(returning: accumulatedFetchResult)
            pendingFetchContinuation = nil

        case .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    private static func exclusionID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("exclusion-") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst("exclusion-".count)))
    }
}
