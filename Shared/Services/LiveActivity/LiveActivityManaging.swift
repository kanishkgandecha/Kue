//
//  LiveActivityManaging.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "A./B." — the DI seam every Live-Activity
//  call site reads through (`SystemLiveActivityManager` in production,
//  `FakeLiveActivityManager` under `KueUITests`/`KueTests`), same "protocol + System + Fake"
//  shape `CalendarProviding`/`OCRTextRecognizing`/`VoiceSpeechRecognizing` already establish.
//  Deliberately thin: every method is either "does the running activity belong to this event"
//  or "start/update/end one specific event's activity" — the *policy* of when to ask for a
//  replacement confirmation lives one layer up, in `LiveActivityFocusCoordinator` (Kue/,
//  app-only), never here.
//

import Foundation

/// A tiny, ActivityKit-decoupled dismissal timing — translated to the real
/// `ActivityUIDismissalPolicy` only inside `SystemLiveActivityManager`, so every other call
/// site (the coordinator, tests) never needs to import ActivityKit just to end an activity.
enum LiveActivityDismissalPolicy: Equatable {
    case immediate
    case after(Date)
    /// The system's own default end-then-linger-then-dismiss behavior.
    case systemDefault
}

enum LiveActivityStartResult: Equatable {
    case started
    case failed(LiveActivityUnavailableReason)
}

/// docs/23 "B.": "Treat authorization-disabled, unsupported, request-failed, and
/// stale/missing-event states distinctly. Do not collapse them into one generic error."
enum LiveActivityUnavailableReason: Equatable {
    case authorizationDisabled
    case unsupported
    /// A *different* event already has the one running Kue-owned activity — the caller
    /// (`LiveActivityFocusCoordinator`) is expected to have already routed this into a
    /// replacement confirmation rather than reaching `start(for:)` at all; surfaced here too
    /// so a direct/misordered call still fails honestly instead of silently double-starting.
    case anotherEventAlreadyFocused(eventID: UUID)
    case requestFailed
}

protocol LiveActivityManaging: Sendable {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled` — Settings toggle, Low Power Mode,
    /// etc. Checked before ever offering "Start" in the UI.
    var isAvailable: Bool { get }

    /// The event id of whichever Kue-owned activity is currently running, if any.
    func focusedEventID() async -> UUID?

    /// Starts a brand-new activity for `event`. Unconditional — the one-event confirmation
    /// policy is the caller's job (`LiveActivityFocusCoordinator`), not this method's.
    func start(for event: KueEvent, now: Date) async -> LiveActivityStartResult

    /// Updates the running activity — a no-op if none is running, or if the one running
    /// belongs to a *different* event than `event.id` (requirement C.7: never silently
    /// switch which event an activity tracks).
    func update(for event: KueEvent, now: Date) async

    /// Ends whichever activity is running for `eventID` specifically — a no-op for any other
    /// event's id.
    func end(eventID: UUID, dismissalPolicy: LiveActivityDismissalPolicy) async

    /// Ends every Kue-owned activity, regardless of which event — used defensively (e.g.
    /// "Delete Everything").
    func endAll() async

    /// The one reconciliation entry point (docs/23 "G."). `event` is whatever the caller
    /// already fetched for the *currently focused* event id (`nil` once it's been deleted).
    /// Never selects a different event — only updates or ends the activity already running
    /// for the id it was started with.
    func reconcileFocusedActivity(with event: KueEvent?, now: Date) async
}
