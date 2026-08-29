//
//  SyncStatus.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "K." Every truthful state the Settings sync section (and Home's
//  restrained banner) can show. A plain value type computed by `SyncCoordinator` from its own
//  current knowledge — never a raw CloudKit error/state leaking into the UI layer.
//

import Foundation

nonisolated enum SyncStatus: Equatable {
    case off
    case checkingAccount
    case upToDate
    case syncing
    case waitingForNetwork
    case waitingForSignIn
    case paused
    case changesWaitingToUpload(count: Int)
    case conflictNeedsReview(count: Int)
    case temporarilyUnavailable
    case syncError(String)
    case accountChanged

    /// Restrained, honest copy — docs/26 "K.": "Do not claim synchronization is immediate."
    var displayText: String {
        switch self {
        case .off: return "Off"
        case .checkingAccount: return "Checking iCloud…"
        case .upToDate: return "Up to Date"
        case .syncing: return "Syncing…"
        case .waitingForNetwork: return "Waiting for Network"
        case .waitingForSignIn: return "Waiting for iCloud Sign-In"
        case .paused: return "Paused"
        case .changesWaitingToUpload(let count): return "\(count) change\(count == 1 ? "" : "s") waiting to upload"
        case .conflictNeedsReview(let count): return "\(count) conflict\(count == 1 ? "" : "s") need review"
        case .temporarilyUnavailable: return "Temporarily Unavailable"
        case .syncError: return "Sync Error"
        case .accountChanged: return "Account Changed"
        }
    }

    /// Whether this state is worth a restrained, persistent Home banner (docs/26 "L.": only
    /// "actionable persistent states such as account change or unresolved conflict" — never a
    /// spinner for every normal save).
    var warrantsHomeBanner: Bool {
        switch self {
        case .accountChanged, .conflictNeedsReview: return true
        default: return false
        }
    }

    /// Worth a warning-tinted row in Settings — not necessarily worth a Home banner (that bar
    /// is higher, see `warrantsHomeBanner`).
    var isErrorLike: Bool {
        switch self {
        case .conflictNeedsReview, .syncError, .temporarilyUnavailable: return true
        default: return false
        }
    }
}
