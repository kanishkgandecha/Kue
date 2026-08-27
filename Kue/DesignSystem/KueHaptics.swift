//
//  KueHaptics.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System, requirement 32/33/34: "restrained haptics," "do not
//  trigger haptics during automated tests," "centralize haptic behavior behind an injectable
//  abstraction." Mirrors this codebase's established DI seam shape exactly — a protocol +
//  system implementation + fake implementation + `EnvironmentKey`, the same pattern
//  `CalendarProviding`/`OCRTextRecognizing`/`VoiceSpeechRecognizing` already use (see
//  AGENTS.md "Project structure" for those) — so haptics get the identical guarantee: a
//  `KueUITests` launch never touches the real Taptic Engine, and `KueTests` never needs to
//  either.
//

import SwiftUI
import UIKit

/// What Kue actually asks the system to feel, named by *meaning* (requirement 32's own list),
/// not by the underlying `UINotificationFeedbackGenerator`/`UIImpactFeedbackGenerator` case —
/// a call site says `.play(.eventCreated)`, not "which generator and which feedback type."
enum KueHapticEvent {
    case eventCreated
    case taskCompleted
    case selectionChanged
    case destructiveConfirmed
    case recordingStarted
    case recordingStopped
    case actionFailed
}

protocol KueHapticPlaying {
    func play(_ event: KueHapticEvent)
}

/// The real implementation — routes each semantic event to the appropriate system feedback
/// generator. Never constructed by a test; see `FakeHapticPlayer` below.
@MainActor
final class SystemHapticPlayer: KueHapticPlaying {
    static let shared = SystemHapticPlayer()
    private init() {}

    func play(_ event: KueHapticEvent) {
        switch event {
        case .eventCreated, .taskCompleted:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .selectionChanged:
            UISelectionFeedbackGenerator().selectionChanged()
        case .destructiveConfirmed:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .recordingStarted:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .recordingStopped:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .actionFailed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// Requirement 33 — installed instead of `SystemHapticPlayer` whenever the process was
/// launched under `KueUITests` (mirrors `ModelContainerFactory.isUITestIsolatedStore`'s own
/// gating), and always used directly (never through the environment) inside `KueTests`,
/// which never touches SwiftUI's environment resolution at all. Records what was requested
/// so a test can assert "the app tried to celebrate this," without ever asking the real
/// Taptic Engine to do anything.
@MainActor
final class FakeHapticPlayer: KueHapticPlaying {
    private(set) var playedEvents: [KueHapticEvent] = []

    func play(_ event: KueHapticEvent) {
        playedEvents.append(event)
    }
}

private struct KueHapticPlayerKey: EnvironmentKey {
    /// Defaulting to the real player (not a no-op) matches every other seam in this codebase
    /// (`CalendarProviding`'s default is `SystemCalendarProvider`, etc.) — the *fake* is what's
    /// explicitly opted into for tests, never the other way around.
    static let defaultValue: any KueHapticPlaying = SystemHapticPlayer.shared
}

extension EnvironmentValues {
    var kueHaptics: any KueHapticPlaying {
        get { self[KueHapticPlayerKey.self] }
        set { self[KueHapticPlayerKey.self] = newValue }
    }
}
