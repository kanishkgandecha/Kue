//
//  SyncStatus.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "Sync status and controls." Every truthful state the Settings sync
//  section (iPhone and Mac) can show. A plain value type computed by `SyncCoordinator` from its
//  own current knowledge — never a raw transport error leaking into the UI layer. Extended from
//  Kue 2.0 Phase 11's `SyncStatus` (docs/26 "K.") for the states Phase 5's product spec calls
//  for by name (local-only, first-sync decision required, authentication expired, retry
//  scheduled, partial failure) — `.off`/`.upToDate`/`.syncing`/`.changesWaitingToUpload`/
//  `.conflictNeedsReview`/`.syncError` already covered their Phase 5 equivalents unchanged.
//  `.changesWaitingToDownload` (Phase 5 correction) — a bounded pull hit its per-pass page cap
//  with more remote pages still pending; never conflated with `.upToDate`.
//

import Foundation

/// Kue 3.0 Phase 5 — docs/33 "First-sync experience." Shared between `AccountFirstSyncDecisionView`
/// (iPhone) and `MacFirstSyncDecisionView` (Mac) — both platforms present the same decision,
/// just in native-per-platform chrome (no shared SwiftUI view file between the two targets,
/// matching every other Kue/Mac screen pair's own precedent).
nonisolated enum AccountFirstSyncDecisionKind: Equatable {
    case notNow
    case proceed(uploadExistingLocalData: Bool)
}

nonisolated enum SyncStatus: Equatable {
    /// The user has explicitly turned sync off (`SyncPreference.isEnabled == false`).
    case off
    /// Signed out, or no Supabase configuration at all — a complete, honest local-only
    /// experience, never framed as an error.
    case localOnly
    /// Signed in, but the account/session is still being established (mirrors
    /// `AccountState.authenticating`) — sync can't start yet, distinct from `.localOnly`.
    case waitingForAccount
    /// Requirement J: sync was just enabled for the first time under this account and the
    /// local-vs-cloud decision hasn't been made yet.
    case firstSyncDecisionRequired
    case syncing
    case upToDate
    case offline
    /// The stored session's refresh failed, or a push/pull was rejected as unauthenticated —
    /// distinct from `.localOnly` (an account exists; its session needs attention).
    case authenticationExpired
    case retryScheduled(at: Date)
    case changesWaitingToUpload(count: Int)
    /// Requirement U/Q (Phase 5 correction): the per-pass page cap was reached while the
    /// server still had more pages to send. Progress already made is safely persisted (the
    /// pull cursor already advanced through every page actually fetched) — this is never
    /// conflated with `.upToDate`; the next automatic or manual sync pass simply continues
    /// downloading from where this one left off.
    case changesWaitingToDownload
    case conflictNeedsReview(count: Int)
    /// Some records pushed/pulled successfully, others didn't (never claimed "up to date").
    case partialFailure(count: Int)
    case syncError(String)

    /// Restrained, honest copy — never claims synchronization is immediate or "done" until both
    /// push and pull actually completed.
    var displayText: String {
        switch self {
        case .off: return "Off"
        case .localOnly: return "Local Only"
        case .waitingForAccount: return "Waiting for Account…"
        case .firstSyncDecisionRequired: return "Decision Needed"
        case .syncing: return "Syncing…"
        case .upToDate: return "Up to Date"
        case .offline: return "Offline"
        case .authenticationExpired: return "Sign In Again to Resume Sync"
        case .retryScheduled(let date): return "Retrying \(date.formatted(.relative(presentation: .named)))"
        case .changesWaitingToUpload(let count): return "\(count) change\(count == 1 ? "" : "s") waiting to upload"
        case .changesWaitingToDownload: return "More changes to download"
        case .conflictNeedsReview(let count): return "\(count) conflict\(count == 1 ? "" : "s") need review"
        case .partialFailure(let count): return "\(count) change\(count == 1 ? "" : "s") didn't sync yet"
        case .syncError: return "Sync Error"
        }
    }

    /// Whether this state is worth a restrained, persistent Home banner — only actionable,
    /// non-transient states, never a spinner for every normal save.
    var warrantsHomeBanner: Bool {
        switch self {
        case .conflictNeedsReview, .authenticationExpired: return true
        default: return false
        }
    }

    var isErrorLike: Bool {
        switch self {
        case .conflictNeedsReview, .syncError, .authenticationExpired, .partialFailure: return true
        default: return false
        }
    }
}
