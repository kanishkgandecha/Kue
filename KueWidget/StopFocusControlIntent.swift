//
//  StopFocusControlIntent.swift
//  KueWidget
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "H." — silent. Calls
//  `LiveActivityManaging.end(eventID:dismissalPolicy:)` directly rather than through
//  `LiveActivityFocusCoordinator.stopFocus` (Kue/Features/LiveActivity/, app-only — not
//  reachable from this extension target); that function is itself only a one-line pass-
//  through to this exact call, so nothing is duplicated. No event parameter: ends whichever
//  activity is currently focused, never a different one — the one honest action Control
//  Center can represent for Focus (Start needs to pick *which* event, which Control Center
//  itself can't do without opening the app — see docs/24 "H." for the full reasoning on why
//  Start isn't offered as a control).
//

import AppIntents
import Foundation

struct StopFocusControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Kue Focus"
    static var description = IntentDescription("Ends whichever event's Live Activity is currently focused in Kue.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = SystemLiveActivityManager.shared
        guard let focusedID = await manager.focusedEventID() else {
            return .result(dialog: "Kue isn't focused on any event right now.")
        }
        await manager.end(eventID: focusedID, dismissalPolicy: .immediate)
        return .result(dialog: "Stopped Kue's focus.")
    }
}
