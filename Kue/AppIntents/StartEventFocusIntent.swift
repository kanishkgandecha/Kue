//
//  StartEventFocusIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.11" — reuses
//  `LiveActivityFocusCoordinator.requestFocus` verbatim (Kue 2.0 Phase 9), so the one-event
//  focus policy is identical regardless of whether Start was tapped in Event Detail or asked
//  of Siri. Confirmation is conditional, not blanket: idempotent same-event restart and a
//  fresh start both need none, but replacing a *different* already-focused event does —
//  requirement C, matching the confirmation dialog Event Detail's own UI already shows.
//

import AppIntents
import SwiftData
import Foundation

struct StartEventFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Event Focus in Kue"
    static var description = IntentDescription("Starts a Live Activity tracking one event in Kue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event", optionsProvider: KueAppEventOptionsProvider())
    var eventIDString: String?

    @Parameter(title: "Or Search Text", default: nil)
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start focus on \(\.$eventIDString) in Kue")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let event = try KueIntentSupport.resolveEvent(eventIDString: eventIDString, query: query, context: context)
        let manager = SystemLiveActivityManager.shared

        switch await LiveActivityFocusCoordinator.requestFocus(for: event, manager: manager) {
        case .started, .alreadyActiveForThisEvent:
            return .result(dialog: "Started a Live Activity for \"\(event.title)\" in Kue.")
        case .needsReplacementConfirmation(let currentEventID):
            let currentTitle = (try? context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == currentEventID })))?.first?.title ?? "another event"
            try await requestConfirmation(dialog: "Kue is already focused on \"\(currentTitle)\". Replace it with \"\(event.title)\"?")
            switch await LiveActivityFocusCoordinator.replaceFocus(currentEventID: currentEventID, with: event, manager: manager) {
            case .started, .alreadyActiveForThisEvent:
                return .result(dialog: "Replaced focus — now tracking \"\(event.title)\" in Kue.")
            case .unavailable(let reason):
                throw KueIntentError.liveActivityUnavailable(reason: Self.message(for: reason))
            case .needsReplacementConfirmation:
                throw KueIntentError.liveActivityUnavailable(reason: "Couldn't switch Kue's focus right now.")
            }
        case .unavailable(let reason):
            throw KueIntentError.liveActivityUnavailable(reason: Self.message(for: reason))
        }
    }

    private static func message(for reason: LiveActivityUnavailableReason) -> String {
        switch reason {
        case .authorizationDisabled:
            return "Live Activities are turned off. Enable them in Settings to track this event on the Lock Screen."
        case .unsupported:
            return "Live Activities aren't supported on this device."
        case .anotherEventAlreadyFocused:
            return "Another event's Live Activity is already active."
        case .requestFailed:
            return "Couldn't start the Live Activity. Try again."
        }
    }
}
