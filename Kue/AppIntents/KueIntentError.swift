//
//  KueIntentError.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "C./K." — the exact set of distinct
//  Siri-facing failure states every intent in this folder throws, so Siri's spoken response
//  (and the Shortcuts app's own error surface) always names the *specific* problem, never a
//  generic "something went wrong." Mirrors `WidgetIntentError`'s own "one case per distinct
//  problem" shape (KueWidget/, Phase 8/9) — this is the main-app-target equivalent, not a
//  duplicate of its logic (no shared code between the two; they cover different intents).
//

import Foundation

enum KueIntentError: Error, LocalizedError, Equatable {
    /// The shared App Group store couldn't be opened at all.
    case storeUnavailable
    /// No `KueEvent` matched the given id/title.
    case eventNotFound
    /// More than one event matched equally well — never resolved to a guess (docs/24 "D.").
    /// Carries up to a handful of titles so Siri's spoken disambiguation names real options.
    case ambiguousEvent(titles: [String])
    case taskNotFound
    /// The resolved event has no remaining (incomplete) task to act on.
    case noRemainingTask
    /// docs/07-widget-engine.md's own snooze-window rule, reused: no time left to snooze.
    case noSnoozeIntervalRemains
    /// No event is eligible for "what's next" right now.
    case noUpcomingEvent
    /// On-device NL parsing isn't available (device/Apple-Intelligence/model-not-ready) or the
    /// user turned AI parsing off in Settings.
    case parsingUnavailable(message: String)
    /// The parser ran but couldn't produce a usable draft, or left ambiguities that must be
    /// resolved in the app before this can be created.
    case draftNeedsConfirmation
    /// A structured field (e.g. an empty title) failed deterministic validation.
    case invalidInput(message: String)
    /// docs/23 "B." — surfaced honestly rather than silently no-op'ing.
    case liveActivityUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "Kue's shared data isn't available right now."
        case .eventNotFound:
            return "I couldn't find that event in Kue."
        case .ambiguousEvent(let titles):
            guard !titles.isEmpty else { return "More than one event matches that — try being more specific." }
            return "More than one event matches that: \(titles.joined(separator: ", ")). Try being more specific."
        case .taskNotFound:
            return "That task no longer exists."
        case .noRemainingTask:
            return "That event has no remaining tasks."
        case .noSnoozeIntervalRemains:
            return "There's no time left to snooze this task."
        case .noUpcomingEvent:
            return "You don't have an upcoming event in Kue right now."
        case .parsingUnavailable(let message):
            return message
        case .draftNeedsConfirmation:
            return "That needs a quick confirmation in Kue before I can create it."
        case .invalidInput(let message):
            return message
        case .liveActivityUnavailable(let reason):
            return reason
        }
    }
}
