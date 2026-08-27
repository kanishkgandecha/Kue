//
//  VoiceSpeechRecognizing.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 4/6/7/8/10: speech recognition, as its
//  own dependency-injected responsibility, separate from microphone capture — this protocol
//  never touches `AVAudioEngine`. `SystemVoiceSpeechRecognizer` is the only file that imports
//  `Speech`; no `SFSpeechRecognizer`/`SFSpeechRecognitionTask`/`SFSpeechRecognitionResult` ever
//  escapes it.
//

import AVFoundation

/// One live recognition request — appended to as capture delivers buffers, finished once the
/// user stops (or a limit/silence/interruption ends the session), cancelled on any termination
/// path that must produce no result at all. Requirement 7: the real implementation always sets
/// `requiresOnDeviceRecognition = true` on the underlying request at creation — this is the
/// mechanism that makes on-device-only structurally guaranteed, not just a default Kue happens
/// to leave unchanged (see docs/20-voice-input.md "On-device enforcement").
@MainActor
protocol VoiceRecognitionRequestHandle: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// Signals no more audio is coming; the in-flight request still delivers its own final
    /// result/error asynchronously afterward.
    func finish()
    /// Requirement 53 — an immediate, silent stop: no further `onUpdate`/`onFailure` callback
    /// should be treated as meaningful after this (the coordinator's own generation guard
    /// enforces that even if the underlying implementation still calls back).
    func cancel()
}

@MainActor
protocol VoiceSpeechRecognizing {
    /// A pure capability check — requirement 8: verified *before* recording ever starts, never
    /// discovered only after the user has already spoken.
    func recognizerAvailability() -> VoiceRecognizerAvailability

    /// Requirement 5/16/31 — `onUpdate` fires for each partial and the one final transcription
    /// (each carrying the *complete* transcript so far, never a fragment); `onFailure` fires at
    /// most once, for a recognition-side failure only (not for a plain, successful `.cancel()`).
    func startRecognition(
        onUpdate: @escaping (VoiceTranscriptionUpdate) -> Void,
        onFailure: @escaping (VoiceRecognitionError) -> Void
    ) throws -> any VoiceRecognitionRequestHandle
}
