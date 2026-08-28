//
//  StopEventFocusIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.12" — reuses
//  `LiveActivityFocusCoordinator.stopFocus` verbatim. No event parameter: ends whichever
//  activity is currently focused (never a different one), matching the Settings focus-
//  management surface's own "Stop" button. No confirmation: ending is low-risk and reversible
//  (re-start any time).
//

import AppIntents
import SwiftData
import Foundation

struct StopEventFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Kue Focus"
    static var description = IntentDescription("Ends whichever event's Live Activity is currently focused in Kue.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = SystemLiveActivityManager.shared
        guard let focusedID = await manager.focusedEventID() else {
            return .result(dialog: "Kue isn't focused on any event right now.")
        }
        let context = try KueIntentSupport.makeContext()
        let title = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == focusedID })))?.first?.title
        await LiveActivityFocusCoordinator.stopFocus(eventID: focusedID, manager: manager)
        return .result(dialog: title.map { "Stopped focus on \"\($0)\" in Kue." } ?? "Stopped Kue's focus.")
    }
}
