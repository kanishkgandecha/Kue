//
//  LiveActivityReconciler.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "G. App lifecycle reconciliation." One
//  bounded, deterministic pass: is there a running activity at all? If so, does its event
//  still exist, and in what state? Never fetches "some other event" — mirrors the Dedicated
//  Countdown widget's own "never fall back to Next Up" policy. Callable from both the app
//  (scenePhase-active, `EventActions`, `EventFormView.save()`) and the widget extension
//  process (`WidgetIntentActions`), which is why it lives in `Shared/` alongside the manager
//  it drives, not in an app-only file.
//

import Foundation
import SwiftData

enum LiveActivityReconciler {
    @discardableResult
    static func reconcile(context: ModelContext, manager: LiveActivityManaging, now: Date = .now) async -> Bool {
        guard let focusedID = await manager.focusedEventID() else { return false }
        let event = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == focusedID })))?.first
        await manager.reconcileFocusedActivity(with: event, now: now)
        return true
    }
}
