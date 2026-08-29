//
//  VoiceMicrophoneCapturing.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 4/6: microphone capture, as its own
//  dependency-injected responsibility, separate from speech recognition itself — this protocol
//  only ever produces raw audio buffers, it has no idea a recognizer exists.
//  `SystemVoiceMicrophoneCapture` is the only file that imports `AVAudioEngine` directly.
//
//  `AVAudioPCMBuffer` crossing this one boundary (capture → whoever appends it to a
//  recognition request) is the same category of exception `CGImage` is for
//  `OCRTextRecognizing` (Kue 2.0 Phase 5) — a plain, general-purpose raw-data interchange type,
//  not a framework-specific *request/result* type. `AVAudioEngine`/`AVAudioSession` themselves
//  never escape this file.
//

import AVFoundation

@MainActor
protocol VoiceMicrophoneCapturing {
    var isCapturing: Bool { get }

    /// Requirement 5 (loads/captures without blocking the main thread — buffers arrive on
    /// whatever queue the engine's tap fires on) — starts the microphone tap, delivering each
    /// captured buffer to `onBuffer`. Throws `VoiceRecognitionError.microphoneUnavailable` /
    /// `.recordingStartFailed` if the engine can't start.
    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws

    /// Requirement 18/30 — stops the tap and releases the engine; idempotent (safe to call when
    /// not capturing). Called on every termination path so nothing keeps capturing once the
    /// voice UI is no longer active.
    func stopCapture()
}
