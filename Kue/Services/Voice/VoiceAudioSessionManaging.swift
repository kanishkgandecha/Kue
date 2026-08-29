//
//  VoiceAudioSessionManaging.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 4/6/17/18/19/20: audio-session
//  coordination, as its own dependency-injected responsibility, separate from microphone
//  capture and speech recognition. `SystemVoiceAudioSessionManager` is the only file that
//  imports `AVFoundation`'s `AVAudioSession` — everyone else reads interruption/route-change
//  events as the Kue-owned types in VoiceKitTypes.swift.
//

import Foundation

@MainActor
protocol VoiceAudioSessionManaging {
    /// Requirement 17 — configures and activates the session *only* when called; never active
    /// otherwise. Throws `VoiceRecognitionError.audioSessionConfigurationFailed` on failure.
    func activate() throws

    /// Requirement 18/19 — deactivates and, in the real implementation, notifies other apps so
    /// their own audio can resume (`.notifyOthersOnDeactivation`) — Kue never leaves the
    /// session claimed longer than one active voice-input attempt needs.
    func deactivate()

    /// Requirement 20 — fires for every interruption for as long as `activate()` is in effect.
    func observeInterruptions(_ handler: @escaping (VoiceInterruptionEvent) -> Void)

    /// Requirement 20 — fires for every route change (e.g. headphones unplugged) for as long as
    /// `activate()` is in effect.
    func observeRouteChanges(_ handler: @escaping (VoiceRouteChangeEvent) -> Void)

    /// Stops observing both — called alongside `deactivate()` so no observer outlives one voice
    /// attempt (requirement 18: cleanup on every termination path).
    func stopObserving()
}
