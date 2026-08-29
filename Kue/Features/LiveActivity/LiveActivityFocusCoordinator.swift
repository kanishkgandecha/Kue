//
//  LiveActivityFocusCoordinator.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "C. One-event focus policy." The layer that
//  actually implements the policy on top of `LiveActivityManaging` — the manager itself is
//  policy-free (start unconditionally, update/end one specific event). Everything about
//  "same event → show management state," "different event → ask first," "replacing ends the
//  old one" lives here, app-only, since it's the app's own UI flow (Event Detail) that drives
//  it — never the widget extension.
//

import Foundation

@MainActor
enum LiveActivityFocusCoordinator {
    enum FocusRequestOutcome: Equatable {
        case started
        case alreadyActiveForThisEvent
        /// The UI must present an explicit confirmation naming both events before calling
        /// `replaceFocus` — requirement C: "It must never silently replace A."
        case needsReplacementConfirmation(currentEventID: UUID)
        case unavailable(LiveActivityUnavailableReason)
    }

    /// The entry point Event Detail's "Start Live Activity" button calls.
    static func requestFocus(for event: KueEvent, manager: LiveActivityManaging, now: Date = .now) async -> FocusRequestOutcome {
        guard manager.isAvailable else { return .unavailable(.authorizationDisabled) }
        if let currentID = await manager.focusedEventID() {
            if currentID == event.id { return .alreadyActiveForThisEvent }
            return .needsReplacementConfirmation(currentEventID: currentID)
        }
        return await startUnconditionally(event, manager: manager, now: now)
    }

    /// Called only after the user has explicitly confirmed replacement in the UI — never
    /// invoked automatically.
    static func replaceFocus(currentEventID: UUID, with newEvent: KueEvent, manager: LiveActivityManaging, now: Date = .now) async -> FocusRequestOutcome {
        await manager.end(eventID: currentEventID, dismissalPolicy: .immediate)
        return await startUnconditionally(newEvent, manager: manager, now: now)
    }

    static func stopFocus(eventID: UUID, manager: LiveActivityManaging) async {
        await manager.end(eventID: eventID, dismissalPolicy: .immediate)
    }

    private static func startUnconditionally(_ event: KueEvent, manager: LiveActivityManaging, now: Date) async -> FocusRequestOutcome {
        switch await manager.start(for: event, now: now) {
        case .started: return .started
        case .failed(let reason): return .unavailable(reason)
        }
    }
}
