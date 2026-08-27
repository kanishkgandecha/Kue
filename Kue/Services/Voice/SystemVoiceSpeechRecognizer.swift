//
//  SystemVoiceSpeechRecognizer.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. The only file that imports `Speech` — requirement
//  3/4/7/8/10/11. `requiresOnDeviceRecognition = true` (set immediately when the request is
//  created, before a single buffer is appended) is the structural on-device-only enforcement
//  mechanism: `SFSpeechRecognitionTask` itself refuses to fall back to a server for this
//  request rather than Kue merely choosing not to ask for one — see docs/20-voice-input.md
//  "On-device enforcement".
//

import Foundation
import Speech

@MainActor
final class SystemVoiceSpeechRecognizer: VoiceSpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func recognizerAvailability() -> VoiceRecognizerAvailability {
        guard let recognizer, recognizer.isAvailable else { return .unavailable }
        guard recognizer.supportsOnDeviceRecognition else { return .onDeviceUnsupported }
        return .availableOnDevice
    }

    func startRecognition(
        onUpdate: @escaping (VoiceTranscriptionUpdate) -> Void,
        onFailure: @escaping (VoiceRecognitionError) -> Void
    ) throws -> any VoiceRecognitionRequestHandle {
        guard let recognizer, recognizerAvailability() == .availableOnDevice else {
            throw VoiceRecognitionError.recordingStartFailed("Speech recognizer unavailable")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Requirement 7/10 — the on-device-only enforcement itself; see file header.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    // `kAFAssistantErrorDomain` code 1110 is Apple's own "No speech detected"
                    // signal — surfaced as its own distinct, non-alarming outcome (requirement
                    // 51) rather than a generic recognition failure.
                    if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
                        onFailure(.noSpeechDetected)
                    } else {
                        onFailure(.recognitionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result else { return }
                onUpdate(VoiceTranscriptionUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
        }

        return Handle(request: request, task: task)
    }

    /// Requirement 3 — the one place `SFSpeechAudioBufferRecognitionRequest`/
    /// `SFSpeechRecognitionTask` are held at all; nothing outside this file ever names either.
    private final class Handle: VoiceRecognitionRequestHandle {
        private let request: SFSpeechAudioBufferRecognitionRequest
        private let task: SFSpeechRecognitionTask

        init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
            self.request = request
            self.task = task
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            request.append(buffer)
        }

        func finish() {
            request.endAudio()
        }

        func cancel() {
            task.cancel()
        }
    }
}
