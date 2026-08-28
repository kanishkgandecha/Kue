//
//  OpenEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.4/J." — opens the exact event via
//  the *same* `KueDeepLink`/`RootTabView.onOpenURL` route a Spotlight tap or a widget tap
//  already uses, never a second in-process navigation mechanism. Read-only in effect (no
//  mutation), so no confirmation — requirement C.
//

import AppIntents
import SwiftData
import Foundation

struct OpenEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Event in Kue"
    static var description = IntentDescription("Opens a specific event in Kue.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        KueIntentSupport.openDeepLink(KueDeepLink.url(for: .event(event.id)))
        return .result(dialog: "Opening \"\(event.title)\" in Kue.")
    }
}
