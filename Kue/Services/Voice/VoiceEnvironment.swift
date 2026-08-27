//
//  VoiceEnvironment.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Dependency injection for all four Voice protocols —
//  views/coordinators read them from the SwiftUI environment rather than constructing the real
//  implementations themselves, mirroring `CalendarEnvironment.swift`/`OCREnvironment.swift`
//  exactly. `KueApp` installs the real implementations at the root (or, launched with
//  `FakeVoiceSpeechRecognizer.uiTestLaunchArgument`, deterministic fakes for all four).
//

import SwiftUI
import AVFAudio

private struct VoiceAuthorizationCheckerKey: EnvironmentKey {
    static let defaultValue: VoiceAuthorizationChecking = UnavailableVoiceAuthorizationChecker()
}
private struct VoiceAudioSessionManagerKey: EnvironmentKey {
    static let defaultValue: VoiceAudioSessionManaging = UnavailableVoiceAudioSessionManager()
}
private struct VoiceMicrophoneCaptureKey: EnvironmentKey {
    static let defaultValue: VoiceMicrophoneCapturing = UnavailableVoiceMicrophoneCapture()
}
private struct VoiceSpeechRecognizerKey: EnvironmentKey {
    static let defaultValue: VoiceSpeechRecognizing = UnavailableVoiceSpeechRecognizer()
}

extension EnvironmentValues {
    var voiceAuthorizationChecker: VoiceAuthorizationChecking {
        get { self[VoiceAuthorizationCheckerKey.self] }
        set { self[VoiceAuthorizationCheckerKey.self] = newValue }
    }
    var voiceAudioSessionManager: VoiceAudioSessionManaging {
        get { self[VoiceAudioSessionManagerKey.self] }
        set { self[VoiceAudioSessionManagerKey.self] = newValue }
    }
    var voiceMicrophoneCapture: VoiceMicrophoneCapturing {
        get { self[VoiceMicrophoneCaptureKey.self] }
        set { self[VoiceMicrophoneCaptureKey.self] = newValue }
    }
    var voiceSpeechRecognizer: VoiceSpeechRecognizing {
        get { self[VoiceSpeechRecognizerKey.self] }
        set { self[VoiceSpeechRecognizerKey.self] = newValue }
    }
}

// MARK: - No-op defaults (never reachable once KueApp installs the real/fake set)

@MainActor
private struct UnavailableVoiceAuthorizationChecker: VoiceAuthorizationChecking {
    func microphoneAuthorizationState() -> VoiceAuthorizationState { .unavailable }
    func speechAuthorizationState() -> VoiceAuthorizationState { .unavailable }
    func requestMicrophoneAuthorization() async -> VoiceAuthorizationState { .unavailable }
    func requestSpeechAuthorization() async -> VoiceAuthorizationState { .unavailable }
}

@MainActor
private struct UnavailableVoiceAudioSessionManager: VoiceAudioSessionManaging {
    func activate() throws { throw VoiceRecognitionError.audioSessionConfigurationFailed("unavailable") }
    func deactivate() {}
    func observeInterruptions(_ handler: @escaping (VoiceInterruptionEvent) -> Void) {}
    func observeRouteChanges(_ handler: @escaping (VoiceRouteChangeEvent) -> Void) {}
    func stopObserving() {}
}

@MainActor
private struct UnavailableVoiceMicrophoneCapture: VoiceMicrophoneCapturing {
    var isCapturing: Bool { false }
    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        throw VoiceRecognitionError.microphoneUnavailable
    }
    func stopCapture() {}
}

@MainActor
private struct UnavailableVoiceSpeechRecognizer: VoiceSpeechRecognizing {
    func recognizerAvailability() -> VoiceRecognizerAvailability { .unavailable }
    func startRecognition(
        onUpdate: @escaping (VoiceTranscriptionUpdate) -> Void,
        onFailure: @escaping (VoiceRecognitionError) -> Void
    ) throws -> any VoiceRecognitionRequestHandle {
        throw VoiceRecognitionError.recordingStartFailed("unavailable")
    }
}
