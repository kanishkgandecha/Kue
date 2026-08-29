//
//  SystemCloudAccountProvider.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "F./G." The one file that translates real `CKAccountStatus`
//  into `CloudAccountState` (Shared/Services/Sync/CloudAccountProviding.swift's own neutral
//  enum). App-only, imports CloudKit — nothing in Shared/ ever does.
//

import CloudKit

nonisolated struct SystemCloudAccountProvider: CloudAccountProviding {
    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitContainerIdentifier.value)) {
        self.container = container
    }

    func currentState() async -> CloudAccountState {
        guard let status = try? await container.accountStatus() else { return .couldNotDetermine }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }

    /// `CKRecord.ID.recordName` of the account's own root user record — a stable, opaque,
    /// CloudKit-internal string scoped to this one container. Never the Apple ID, name, or
    /// email (docs/26 "G."): CloudKit itself never exposes those to the app at all.
    func currentAccountFingerprint() async -> String? {
        guard let recordID = try? await container.userRecordID() else { return nil }
        return recordID.recordName
    }
}
