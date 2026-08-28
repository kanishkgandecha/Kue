//
//  ShowNextEventControlIntent.swift
//  KueWidget
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "H." — opens Kue
//  (`openAppWhenRun = true`). Same genuine platform limitation as `QuickAddControlIntent`:
//  an extension-declared intent can foreground the app but can't call
//  `UIApplication.shared.open(_:)` to deep-link to a specific screen. Honest fallback: Home's
//  own date-sectioned timeline already surfaces the next event at the top, so simply opening
//  the app still answers "what's next" at a glance — never a silently *wrong* event, just a
//  one-tap-further honest one.
//

import AppIntents
import Foundation

struct ShowNextEventControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Next Event"
    static var description = IntentDescription("Opens Kue to your next upcoming event.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
