//
//  PlanningFocusActions.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "E. Focus blocks": "start Event Focus Mode when appropriate."
//  iOS-only, alongside `LiveActivityFocusCoordinator` itself (`Kue/Features/LiveActivity/`) —
//  Live Activities/Dynamic Island don't exist on macOS, and `Shared/` compiles into the
//  `KueMac` target too, so this one action lives here rather than in
//  `PlanningActionRouter` (see that file's own note). Everything else a recommendation can do
//  is genuinely cross-platform and stays in the shared router.
//

import Foundation
import SwiftData

@MainActor
extension PlanningActionRouter {
    /// Reuses `LiveActivityFocusCoordinator` verbatim — the same call
    /// `StartEventFocusIntent`/Event Detail's own "Start Live Activity" button makes.
    static func startFocus(for block: FocusBlockProposal, context: ModelContext, manager: LiveActivityManaging) async throws -> LiveActivityFocusCoordinator.FocusRequestOutcome {
        guard let eventID = block.eventID, let event = try fetchEvent(id: eventID, context: context) else {
            throw RoutingError.eventNotFound
        }
        return await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager)
    }
}
