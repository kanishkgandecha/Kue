//
//  FakeLiveActivityManager.swift
//  Kue
//
//  Deterministic in-memory `LiveActivityManaging` — no real ActivityKit call anywhere, so
//  `KueTests` and `KueUITests` never touch the real Live Activity system. See docs/23-live-
//  activities-and-focus-mode.md "L." Installed under `KueUITests` the same launch-argument-
//  gated way `FakeCalendarProvider`/`FakeOCRTextRecognizer`/`FakeVoiceSpeechRecognizer` are —
//  see `KueApp.swift`'s own installation call site — never reachable in a production build
//  by accident.
//

import Foundation

@MainActor
final class FakeLiveActivityManager: LiveActivityManaging {
    /// Must match `UITestLaunchConfiguration`'s identical literal (KueUITests/) exactly —
    /// same "shared constant, same rationale" as every other fake-service launch argument in
    /// this codebase.
    static let uiTestLaunchArgument = "-uiTestFakeLiveActivity"

    /// `nil` when `uiTestLaunchArgument` isn't present — `KueApp` falls back to
    /// `SystemLiveActivityManager.shared` in that case.
    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeLiveActivityManager? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        return FakeLiveActivityManager()
    }

    /// Fixed per test instance — set `false` to simulate `.authorizationDisabled`/
    /// `.unsupported` without touching real ActivityKit state.
    var isAvailable = true

    private(set) var runningEventID: UUID?
    private(set) var lastContentState: KueLiveActivityAttributes.ContentState?
    private(set) var endedEventIDs: [UUID] = []
    private(set) var startCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var reconcileCallCount = 0

    func focusedEventID() async -> UUID? {
        runningEventID
    }

    func start(for event: KueEvent, now: Date) async -> LiveActivityStartResult {
        startCallCount += 1
        guard isAvailable else { return .failed(.authorizationDisabled) }
        if let runningEventID {
            if runningEventID == event.id { return .started } // idempotent, matches SystemLiveActivityManager
            return .failed(.anotherEventAlreadyFocused(eventID: runningEventID))
        }
        runningEventID = event.id
        lastContentState = LiveActivityStateBuilder.contentState(for: event, now: now)
        return .started
    }

    func update(for event: KueEvent, now: Date) async {
        updateCallCount += 1
        guard runningEventID == event.id else { return }
        lastContentState = LiveActivityStateBuilder.contentState(for: event, now: now)
    }

    func end(eventID: UUID, dismissalPolicy: LiveActivityDismissalPolicy) async {
        guard runningEventID == eventID else { return }
        runningEventID = nil
        lastContentState = nil
        endedEventIDs.append(eventID)
    }

    func endAll() async {
        if let runningEventID {
            endedEventIDs.append(runningEventID)
        }
        runningEventID = nil
        lastContentState = nil
    }

    func reconcileFocusedActivity(with event: KueEvent?, now: Date) async {
        reconcileCallCount += 1
        guard let focusedID = runningEventID else { return }
        guard let event else {
            lastContentState = LiveActivityStateBuilder.unavailableContentState(eventType: .generic, now: now)
            endedEventIDs.append(focusedID)
            runningEventID = nil
            return
        }
        guard event.id == focusedID else { return }
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        lastContentState = LiveActivityStateBuilder.contentState(for: event, now: now)
        switch resolution {
        case .tracking(let content) where content.phase == .completed || content.phase == .removed:
            endedEventIDs.append(focusedID)
            runningEventID = nil
        // Kue 2.0 Phase 10.1 — docs/25 "G." — mirrors `SystemLiveActivityManager`'s own
        // grace-period gate exactly, so fake-driven tests exercise the identical policy.
        case .tracking(let content) where content.phase == .awaitingOutcome:
            if now >= event.effectiveEndDate.addingTimeInterval(LiveActivityPolicy.awaitingOutcomeGracePeriod) {
                endedEventIDs.append(focusedID)
                runningEventID = nil
            }
        case .cancelled, .skipped:
            endedEventIDs.append(focusedID)
            runningEventID = nil
        default:
            break
        }
    }

    /// Test convenience — resets every recorded call/state between cases in the same file.
    func reset() {
        isAvailable = true
        runningEventID = nil
        lastContentState = nil
        endedEventIDs = []
        startCallCount = 0
        updateCallCount = 0
        reconcileCallCount = 0
    }
}
