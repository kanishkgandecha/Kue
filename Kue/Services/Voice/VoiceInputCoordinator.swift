//
//  VoiceInputCoordinator.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 6: "voice-flow state management" as
//  its own responsibility, separate from audio-session coordination, microphone capture, and
//  speech recognition (each already its own DI-injected protocol) and separate from the view
//  itself. This class is the only place that wires those three services together — none of
//  them know the other two exist.
//
//  Timing (requirement 26/27/28) is driven by `tick(now:)`, called periodically by the view via
//  a repeating timer, rather than this class owning a real `Timer`/`Date.now` internally — the
//  same "take `now: Date` as a parameter" shape every other time-sensitive engine in this
//  codebase already uses (`EventActions`, `EventStatusEngine`, ...), so silence/max-duration
//  logic is exercised deterministically in `KueTests` with synthetic dates, no real waiting.
//

import Foundation
import AVFAudio

@MainActor
@Observable
final class VoiceInputCoordinator {
    private(set) var phase: VoiceRecordingPhase = .idle
    private(set) var transcript: String = ""
    private(set) var elapsedSeconds: Int = 0
    private(set) var confidence: VoiceConfidence = .high
    private(set) var authorization: VoiceAuthorizationSnapshot = VoiceAuthorizationSnapshot(microphone: .notDetermined, speech: .notDetermined)
    private(set) var recognizerAvailability: VoiceRecognizerAvailability = .unavailable
    /// Requirement 26/27/28 — set immediately before an automatic (not user-tapped) stop, so
    /// the review screen can say *why* recording ended without that ever being confused with a
    /// hard error.
    private(set) var autoStopReason: String?
    /// Requirement 32/33/34 — once the user has touched the transcript themselves, no further
    /// programmatic update (a late-arriving final result) is ever allowed to overwrite it. Set
    /// by the view's own `TextEditor` binding, read here.
    var hasUserEdited = false

    private let authorizationChecker: VoiceAuthorizationChecking
    private let audioSessionManager: VoiceAudioSessionManaging
    private let microphoneCapture: VoiceMicrophoneCapturing
    private let speechRecognizer: VoiceSpeechRecognizing

    private var generation = VoiceRequestGeneration()
    private var recognitionHandle: (any VoiceRecognitionRequestHandle)?
    private var recordingStartDate: Date?
    private var lastTranscriptChangeDate: Date?
    private var latestSegmentConfidences: [Float] = []

    init(
        authorizationChecker: VoiceAuthorizationChecking,
        audioSessionManager: VoiceAudioSessionManaging,
        microphoneCapture: VoiceMicrophoneCapturing,
        speechRecognizer: VoiceSpeechRecognizing
    ) {
        self.authorizationChecker = authorizationChecker
        self.audioSessionManager = audioSessionManager
        self.microphoneCapture = microphoneCapture
        self.speechRecognizer = speechRecognizer
    }

    // MARK: - Availability (requirement 8/12)

    /// A pure read — requirement 12: never itself requests anything. Call on appear and after
    /// returning from Settings ("retry" — requirement 9).
    func refreshAvailability() {
        authorization = VoiceAuthorizationSnapshot(
            microphone: authorizationChecker.microphoneAuthorizationState(),
            speech: authorizationChecker.speechAuthorizationState()
        )
        recognizerAvailability = speechRecognizer.recognizerAvailability()
    }

    // MARK: - Start (requirement 11/21/22/23)

    /// Requirement 21/22 — a no-op while already recording, so a rapid double-tap on "Start
    /// Recording" can never open two simultaneous sessions.
    func startRecording() async {
        guard phase == .idle || isErrorOrNoSpeechPhase else { return }
        autoStopReason = nil
        transcript = ""
        hasUserEdited = false
        latestSegmentConfidences = []

        refreshAvailability()
        // Requirement 11 — permissions are requested here, only from this deliberate call, and
        // only for whichever of the two isn't already decided.
        if authorization.microphone == .notDetermined {
            let result = await authorizationChecker.requestMicrophoneAuthorization()
            authorization.microphone = result
        }
        if authorization.speech == .notDetermined {
            let result = await authorizationChecker.requestSpeechAuthorization()
            authorization.speech = result
        }
        guard authorization.isFullyAuthorized else {
            phase = .error(authorization.blockingExplanation ?? "Voice input isn't available right now.")
            return
        }
        guard recognizerAvailability.canRecord else {
            phase = .error(recognizerAvailability.explanation ?? "Voice input isn't available right now.")
            return
        }

        let myGeneration = generation.advance()

        do {
            try audioSessionManager.activate()
        } catch {
            phase = .error(VoiceRecognitionError.audioSessionConfigurationFailed("\(error)").errorDescription ?? "")
            return
        }
        audioSessionManager.observeInterruptions { [weak self] event in
            self?.handleInterruption(event, generation: myGeneration)
        }
        audioSessionManager.observeRouteChanges { [weak self] event in
            self?.handleRouteChange(event, generation: myGeneration)
        }

        do {
            let handle = try speechRecognizer.startRecognition(
                onUpdate: { [weak self] update in self?.handleUpdate(update, generation: myGeneration) },
                onFailure: { [weak self] error in self?.handleFailure(error, generation: myGeneration) }
            )
            recognitionHandle = handle
            try microphoneCapture.startCapture { [weak self] buffer in
                handle.append(buffer)
                self?.noteBufferCaptured(generation: myGeneration)
            }
        } catch let error as VoiceRecognitionError {
            teardownServices()
            phase = .error(error.errorDescription ?? "Couldn't start recording.")
            return
        } catch {
            teardownServices()
            phase = .error("Couldn't start recording.")
            return
        }

        recordingStartDate = .now
        lastTranscriptChangeDate = .now
        elapsedSeconds = 0
        phase = .recording
    }

    // MARK: - Timing (requirement 25/26/27/28)

    /// Called periodically by the view while `phase == .recording`. Pure with respect to
    /// `now`, so this is exercised in `KueTests` with synthetic dates.
    func tick(now: Date = .now) {
        guard phase == .recording, let recordingStartDate, let lastTranscriptChangeDate else { return }
        elapsedSeconds = Int(now.timeIntervalSince(recordingStartDate))
        if now.timeIntervalSince(recordingStartDate) >= VoiceLimits.maxRecordingDuration {
            autoStopReason = "Stopped automatically — reached the maximum recording time."
            stopRecording()
            return
        }
        if now.timeIntervalSince(lastTranscriptChangeDate) >= VoiceLimits.silenceTimeout {
            autoStopReason = "Stopped automatically after a period of silence."
            stopRecording()
            return
        }
    }

    // MARK: - Stop / cancel / retry (requirement 23/32/50/53)

    func stopRecording() {
        guard phase == .recording else { return }
        recognitionHandle?.finish()
        microphoneCapture.stopCapture()
        audioSessionManager.deactivate()
        audioSessionManager.stopObserving()
        phase = .finalizing
    }

    /// Requirement 50/53 — propagates through capture, recognition, and the audio session;
    /// leaves no transcript, no audio artifact, and (via the generation advance) guarantees any
    /// callback still in flight from the cancelled session is ignored everywhere else in this
    /// class.
    func cancel() {
        generation.advance()
        recognitionHandle?.cancel()
        recognitionHandle = nil
        teardownServices()
        transcript = ""
        hasUserEdited = false
        autoStopReason = nil
        recordingStartDate = nil
        lastTranscriptChangeDate = nil
        elapsedSeconds = 0
        phase = .idle
    }

    /// Requirement 32 — the view calls this (alongside setting `hasUserEdited = true`) whenever
    /// the user types into the transcript editor; kept as an explicit method rather than a
    /// public setter so every call site reads as "the user changed this," matching how
    /// `hasUserEdited` gates every *programmatic* update in `handleUpdate(_:generation:)`.
    func setTranscript(_ text: String) {
        transcript = text
    }

    /// Requirement 9 — "allow retry when availability may have changed": re-checks from
    /// scratch rather than assuming the previous failure still applies.
    func retry() {
        phase = .idle
        autoStopReason = nil
        refreshAvailability()
    }

    // MARK: - Callbacks (requirement 31/32/33/34/54/55)

    private func handleUpdate(_ update: VoiceTranscriptionUpdate, generation myGeneration: Int) {
        guard generation.isCurrent(myGeneration) else { return } // requirement 54: stale/superseded session
        lastTranscriptChangeDate = .now
        // Requirement 32/33/34 — a user edit always wins; a late-arriving update (even the
        // final one) is silently dropped once the user has started editing, never applied.
        if !hasUserEdited {
            transcript = update.text
        }
        if update.isFinal {
            finalizeIfStillRecognizing()
        }
    }

    private func handleFailure(_ error: VoiceRecognitionError, generation myGeneration: Int) {
        guard generation.isCurrent(myGeneration) else { return }
        teardownServices()
        if error == .noSpeechDetected, transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .noSpeechDetected
        } else if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .error(error.errorDescription ?? "Couldn't transcribe that recording.")
        } else {
            // Requirement 34 — a recognition-side failure after some real text was already
            // captured still lets the user review/keep what was transcribed rather than losing
            // it to a hard error screen.
            finalizeIfStillRecognizing()
        }
    }

    private func handleInterruption(_ event: VoiceInterruptionEvent, generation myGeneration: Int) {
        guard generation.isCurrent(myGeneration), phase == .recording else { return }
        autoStopReason = "Recording was interrupted."
        stopRecording()
    }

    private func handleRouteChange(_ event: VoiceRouteChangeEvent, generation myGeneration: Int) {
        // Requirement 20 — handled deterministically: any route change during an active
        // recording stops and finalizes, the same as an interruption, rather than trying to
        // reason about which specific reason is "safe" to keep recording through.
        guard generation.isCurrent(myGeneration), phase == .recording else { return }
        autoStopReason = "Recording stopped because the audio route changed."
        stopRecording()
    }

    private func noteBufferCaptured(generation myGeneration: Int) {
        // Reserved for a future real confidence/level meter; buffers themselves don't carry
        // confidence — only final recognition segments do (requirement 51's "low-confidence
        // transcription where available" is computed from `VoiceRecognitionResult`, not here).
    }

    private func finalizeIfStillRecognizing() {
        guard phase == .recording || phase == .finalizing else { return }
        microphoneCapture.stopCapture()
        audioSessionManager.deactivate()
        audioSessionManager.stopObserving()
        confidence = VoiceConfidence.aggregate(segmentConfidences: latestSegmentConfidences)
        phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSpeechDetected : .reviewing
    }

    private func teardownServices() {
        microphoneCapture.stopCapture()
        audioSessionManager.deactivate()
        audioSessionManager.stopObserving()
    }

    private var isErrorOrNoSpeechPhase: Bool {
        if case .error = phase { return true }
        return phase == .noSpeechDetected
    }
}
