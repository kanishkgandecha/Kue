//
//  LiveActivityActionSet.swift
//  Kue
//
//  Post-Phase-12 fix — Live Activity visual redesign (docs/23 "K."). The Lock Screen and Dynamic
//  Island Expanded Bottom views both decided "which actions apply" from the same three-condition
//  `if`/`else if` inline — this pulls that one decision into a single pure function so it's
//  stated once (not duplicated across two view files) and is unit-testable. Lives in `Shared/`,
//  not `KueWidget/`, specifically so `KueTests` can reach it via `@testable import Kue` — the
//  same reasoning `EventTypeAccent.swift`'s header already documents for the accent mapper.
//  Never re-derives lifecycle: it only reads the already-computed `ContentState`.
//

import Foundation

enum LiveActivityActionSet: Equatable {
    /// Complete Task (+ Snooze if `canSnoozeNextTask`) and Mark Complete.
    case activeWithNextTask
    /// Mark Complete only — genuinely tracking, but no next task exists.
    case activeNoNextTask
    /// Confirm Outcome only (a `Link` to the outcome flow, never a one-tap complete — docs/25 "G.").
    case awaitingOutcome
    /// Terminal (`cancelled`/`skipped`/`unavailable`) or `.completed`/`.removed` — no actions.
    case none
}

func actionSet(for state: KueLiveActivityAttributes.ContentState) -> LiveActivityActionSet {
    guard state.terminal == nil, state.phase != .completed, state.phase != .removed else {
        return .none
    }
    if state.phase == .awaitingOutcome {
        return .awaitingOutcome
    }
    return state.nextTaskID != nil ? .activeWithNextTask : .activeNoNextTask
}
