//
//  QuickAddControlIntent.swift
//  KueWidget
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "H." — the Control Center/Lock Screen
//  "Quick Add" control's action. Quick Add needs free-text input Control Center itself can't
//  provide, so this simply opens Kue (`openAppWhenRun = true`) rather than guessing at a
//  title — the system handles bringing the app to the foreground; no `UIApplication` call is
//  needed (and none would compile here — `UIApplication.shared` is extension-unavailable).
//  Once open, the user reaches Quick Add exactly as they would by tapping the app icon and the
//  Add tab — this control just saves that one tap from Control Center/Lock Screen.
//

import AppIntents
import Foundation

struct QuickAddControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Add"
    static var description = IntentDescription("Opens Kue to add a new event.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
