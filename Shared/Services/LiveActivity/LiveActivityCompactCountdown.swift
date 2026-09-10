//
//  LiveActivityCompactCountdown.swift
//  Kue
//
//  Kue 3.0 Phase 2 (docs/30-kue-3-live-activities-and-dynamic-island.md) — pure formatting for
//  the tightest spaces in this feature (Dynamic Island Compact Trailing/Minimal, the Lock
//  Screen's Compact/Minimal tiers): a short countdown/state word ("19d," "3h," "Now,"
//  "Review," "Done"), never a re-derivation of lifecycle status. `phase`/`terminal` remain the
//  one source of truth (`WidgetContentService`/`DedicatedWidgetContentService`,
//  `LiveActivityStateBuilder`); this only formats the already-known `effectiveStartDate`/
//  `effectiveEndDate` timestamps `LiveActivityStateBuilder` now populates with the real event
//  window (previously both fields were always stubbed to `now` — dead data with nothing to
//  format from; see that file's own Phase 2 comment). Lives in `Shared/`, not `KueWidget/`, so
//  `KueTests` can reach it via `@testable import Kue` — same reasoning `LiveActivityActionSet
//  .swift`'s own header already documents.
//

#if os(iOS)
import Foundation

enum LiveActivityCompactCountdown {
    /// The one place both Dynamic Island's Compact Trailing and every Lock Screen tier read a
    /// short lifecycle/countdown word from. Deterministic in `now` and the already-known
    /// `state` fields only.
    static func label(for state: KueLiveActivityAttributes.ContentState, now: Date = .now) -> String {
        if let terminal = state.terminal {
            switch terminal {
            case .cancelled: return "Cancelled"
            case .skipped: return "Skipped"
            case .unavailable: return "Gone"
            }
        }
        switch state.phase {
        case .awaitingOutcome: return "Review"
        case .completed: return "Done"
        case .removed: return "Archived"
        case .countdown, .preparation, .tomorrow, .today:
            return timeLabel(from: now, to: state.effectiveStartDate, endDate: state.effectiveEndDate)
        }
    }

    /// "Now" while genuinely inside `[effectiveStartDate, effectiveEndDate)`, or once
    /// `effectiveEndDate` has already passed but `phase` hasn't reconciled to
    /// `.awaitingOutcome` yet (a brief real window right at that boundary — reads as "Now,"
    /// never a stale future countdown). Otherwise the time remaining until start, bucketed to
    /// the coarsest unit that stays ≥ 1: minutes, then hours, then days — matching the
    /// resolution a person actually cares about at that distance (nobody reads "2,880 minutes"
    /// as more useful than "2d").
    private static func timeLabel(from now: Date, to startDate: Date, endDate: Date) -> String {
        if now >= startDate { return "Now" }
        let minutes = Int(startDate.timeIntervalSince(now) / 60)
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
#endif
