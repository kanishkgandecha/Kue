//
//  CloudStatisticsStatus.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "Preference and consent." Every truthful state the Insights
//  screen's cloud-statistics section can show — requirement F's exact list: "Local Only,
//  Uploading, Up to Date, Offline, Sign In Required, or Error." A plain value type computed by
//  `StatisticsCoordinator` from its own current knowledge, never a raw transport error leaking
//  into the UI layer — same shape `SyncStatus` (Shared/Services/Sync/) already establishes.
//

import Foundation

nonisolated enum CloudStatisticsStatus: Equatable {
    /// The preference is off (the default) — the normal, expected state for most users, never
    /// framed as an error or a missed opportunity.
    case localOnly
    /// The preference is on, but no account is signed in — requirement F: "if a signed-out
    /// user enables the option, guide them to sign in without losing local data."
    case signInRequired
    case uploading
    case upToDate(at: Date)
    case offline
    case error(String)

    var displayText: String {
        switch self {
        case .localOnly: return "Local Only"
        case .signInRequired: return "Sign In Required"
        case .uploading: return "Uploading…"
        case .upToDate(let date): return "Up to Date (\(date.formatted(.relative(presentation: .named))))"
        case .offline: return "Offline"
        case .error: return "Error"
        }
    }

    var isErrorLike: Bool {
        switch self {
        case .error: return true
        default: return false
        }
    }
}
