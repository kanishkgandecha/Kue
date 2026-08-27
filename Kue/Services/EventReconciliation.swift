//
//  EventReconciliation.swift
//  Kue
//
//  See docs/04-event-types.md "Reconciliation" — the full sweep pass (recompute + persist
//  status, auto-archive where due) plus the widget reload that must follow it when anything
//  actually changed. Pulled out of HomeView so it's callable from anywhere that isn't itself
//  a SwiftUI view: Phase 9's App Intents (which must reconcile after writing) and a future
//  `BGAppRefreshTask` handler both need exactly this entry point, not view-specific wiring.
//

import Foundation
import SwiftData

enum EventReconciliation {
    @discardableResult
    static func run(context: ModelContext, now: Date = .now) -> Bool {
        let statusChanged = EventStatusEngine.sweep(context: context, now: now)
        // Kue 2.0 Phase 3 — docs/17-recurring-events.md "Reconciliation wiring": replenish the
        // rolling occurrence horizon at exactly the same points status reconciliation already
        // runs (app launch/foreground, best-effort BGAppRefreshTask).
        let occurrencesChanged = OccurrenceReconciliationService.replenishAll(context: context, now: now)
        let changed = statusChanged || occurrencesChanged
        if changed {
            EventActions.reloadWidget()
        }
        return changed
    }
}
