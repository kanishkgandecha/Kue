//
//  FakeVoiceServices.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Deterministic, in-memory conformers for all four
//  DI protocols — never touch `AVAudioSession`/`AVAudioEngine`/`Speech`, so they're safe both
//  from `KueTests` (requirement 60/61, `@testable import Kue`) and, launch-configured, from
//  inside the real app process driven by `KueUITests` (requirement 63: never the simulator's
//  or owner's real microphone). Lives in the main target, not KueTests, for the same reason
//  `FakeCalendarProvider`/`FakeOCRTextRecognizer` do — `KueApp` needs to be able to install
//  them.
//

import Foundation
import AVFAudio

@MainActor
final class FakeVoiceAuthorizationChecker: VoiceAuthorizationChecking {
    /// Requirement 59/63 — selects the denied/restricted fixture `KueApp` installs alongside
    /// `FakeVoiceSpeechRecognizer.uiTestLaunchArgument`; defined here (not on the speech
    /// recognizer fake) since these two arguments are specifically about *authorization*, not
    /// recognizer availability.
    static let uiTestMicrophoneDeniedArgument = "-uiTestFakeVoiceMicrophoneDenied"
    static let uiTestSpeechRestrictedArgument = "-uiTestFakeVoiceSpeechRestricted"

    var microphoneStateToReturn: VoiceAuthorizationState = .notDetermined
    var speechStateToReturn: VoiceAuthorizationState = .notDetermined
    var microphoneRequestResult: VoiceAuthorizationState = .authorized
    var speechRequestResult: VoiceAuthorizationState = .authorized
    private(set) var microphoneRequestCount = 0
    private(set) var speechRequestCount = 0

    func microphoneAuthorizationState() -> VoiceAuthorizationState { microphoneStateToReturn }
    func speechAuthorizationState() -> VoiceAuthorizationState { speechStateToReturn }

    func requestMicrophoneAuthorization() async -> VoiceAuthorizationState {
        microphoneRequestCount += 1
        microphoneStateToReturn = microphoneRequestResult
        return microphoneStateToReturn
    }

    func requestSpeechAuthorization() async -> VoiceAuthorizationState {
        speechRequestCount += 1
        speechStateToReturn = speechRequestResult
        return speechStateToReturn
    }
}

@MainActor
final class FakeVoiceAudioSessionManager: VoiceAudioSessionManaging {
    static let uiTestSimulateInterruptionArgument = "-uiTestFakeVoiceInterruption"

    var activateError: VoiceRecognitionError?
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0
    private var interruptionHandler: ((VoiceInterruptionEvent) -> Void)?
    private var routeChangeHandler: ((VoiceRouteChangeEvent) -> Void)?
    /// Requirement 62/63 — a black-box-testable interruption: `KueApp` sets this from
    /// `uiTestSimulateInterruptionArgument` so a `KueUITests` case can observe Voice's real
    /// interruption-handling UI without any way to call into the app process directly.
    var simulateInterruptionAfterNanoseconds: UInt64?

    func activate() throws {
        activateCallCount += 1
        if let activateError { throw activateError }
        if let delay = simulateInterruptionAfterNanoseconds {
            Task {
                try? await Task.sleep(nanoseconds: delay)
                self.interruptionHandler?(.began)
            }
        }
    }

    func deactivate() {
        deactivateCallCount += 1
    }

    func observeInterruptions(_ handler: @escaping (VoiceInterruptionEvent) -> Void) {
        interruptionHandler = handler
    }

    func observeRouteChanges(_ handler: @escaping (VoiceRouteChangeEvent) -> Void) {
        routeChangeHandler = handler
    }

    func stopObserving() {
        interruptionHandler = nil
        routeChangeHandler = nil
    }

    /// Test-only hooks — simulate what a real interruption/route change would deliver.
    func simulateInterruption(_ event: VoiceInterruptionEvent) { interruptionHandler?(event) }
    func simulateRouteChange(_ event: VoiceRouteChangeEvent) { routeChangeHandler?(event) }
}

@MainActor
final class FakeVoiceMicrophoneCapture: VoiceMicrophoneCapturing {
    private(set) var isCapturing = false
    var startCaptureError: VoiceRecognitionError?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        startCallCount += 1
        if let startCaptureError { throw startCaptureError }
        self.onBuffer = onBuffer
        isCapturing = true
    }

    func stopCapture() {
        stopCallCount += 1
        onBuffer = nil
        isCapturing = false
    }

    /// Test-only — a real buffer isn't needed since `FakeVoiceSpeechRecognizer`'s handle
    /// ignores whatever's appended; this exists only to prove capture→recognition wiring calls
    /// through when a test needs that.
    func simulateBufferCaptured() {
        guard isCapturing else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        onBuffer?(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!)
    }
}

@MainActor
final class FakeVoiceSpeechRecognizer: VoiceSpeechRecognizing {
    static let uiTestLaunchArgument = "-uiTestFakeVoice"
    static let uiTestOnDeviceUnsupportedArgument = "-uiTestFakeVoiceOnDeviceUnsupported"
    static let uiTestUnavailableArgument = "-uiTestFakeVoiceUnavailable"
    static let uiTestNoSpeechArgument = "-uiTestFakeVoiceNoSpeech"
    static let uiTestFailureArgument = "-uiTestFakeVoiceFailure"
    static let uiTestLowConfidenceArgument = "-uiTestFakeVoiceLowConfidence"

    var availabilityToReturn: VoiceRecognizerAvailability = .availableOnDevice
    /// Updates delivered, in order, once `simulateUpdates()` is called (or automatically —
    /// see `autoDeliverAfterNanoseconds`). Each is a full-so-far transcript, matching the real
    /// contract (requirement 31).
    var updatesToDeliver: [VoiceTranscriptionUpdate] = []
    var failureToDeliver: VoiceRecognitionError?
    /// Only ever non-zero for UI-test-launched instances — long enough for `VoiceInputView`'s
    /// recording state to be reliably observable, mirroring
    /// `FakeOCRTextRecognizer.artificialDelayNanoseconds`'s own rationale (Kue 2.0 Phase 5).
    var autoDeliverAfterNanoseconds: UInt64 = 0
    /// Gap between successive queued partials once delivery starts. Zero (the default, used by
    /// every `KueTests` case that constructs this fake directly) delivers the whole
    /// `updatesToDeliver` sequence back-to-back right after `autoDeliverAfterNanoseconds` — only
    /// `makeFromLaunchArguments()`'s UI-test instance sets this, so each partial is individually
    /// observable by a UI test's own polling instead of SwiftUI coalescing them into one redraw.
    var interUpdateDelayNanoseconds: UInt64 = 0
    private(set) var startCallCount = 0

    func recognizerAvailability() -> VoiceRecognizerAvailability { availabilityToReturn }

    func startRecognition(
        onUpdate: @escaping (VoiceTranscriptionUpdate) -> Void,
        onFailure: @escaping (VoiceRecognitionError) -> Void
    ) throws -> any VoiceRecognitionRequestHandle {
        guard availabilityToReturn == .availableOnDevice else {
            throw VoiceRecognitionError.recordingStartFailed("Speech recognizer unavailable")
        }
        startCallCount += 1
        let handle = Handle()
        if autoDeliverAfterNanoseconds > 0 {
            let updates = updatesToDeliver
            let failure = failureToDeliver
            let gap = interUpdateDelayNanoseconds
            Task {
                try? await Task.sleep(nanoseconds: autoDeliverAfterNanoseconds)
                guard !handle.isCancelled else { return }
                for (index, update) in updates.enumerated() {
                    guard !handle.isCancelled else { return }
                    onUpdate(update)
                    if gap > 0, index < updates.count - 1 {
                        try? await Task.sleep(nanoseconds: gap)
                    }
                }
                if let failure { onFailure(failure) }
            }
        }
        return handle
    }

    /// Test-only — manually deliver the configured updates/failure (for `KueTests`, which
    /// doesn't want a real async sleep).
    func deliverConfiguredUpdates(onUpdate: (VoiceTranscriptionUpdate) -> Void, onFailure: (VoiceRecognitionError) -> Void) {
        for update in updatesToDeliver { onUpdate(update) }
        if let failureToDeliver { onFailure(failureToDeliver) }
    }

    private final class Handle: VoiceRecognitionRequestHandle {
        private(set) var isCancelled = false
        private(set) var isFinished = false
        func append(_ buffer: AVAudioPCMBuffer) {}
        func finish() { isFinished = true }
        func cancel() { isCancelled = true }
    }

    // MARK: - Launch-argument selection (requirement 59/63)

    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeVoiceSpeechRecognizer? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        let recognizer = FakeVoiceSpeechRecognizer()
        // Longer than `FakeOCRTextRecognizer`'s own equivalent delay (Kue 2.0 Phase 5): the
        // recording state needs to stay observable across *two* sequential UI-test element
        // lookups (the indicator, then the duration label), not just one — empirically, 1.5s
        // left too little margin once both queries' own real round-trip overhead was
        // accounted for.
        let uiTestDelay: UInt64 = 3_000_000_000
        if arguments.contains(uiTestOnDeviceUnsupportedArgument) {
            recognizer.availabilityToReturn = .onDeviceUnsupported
            return recognizer
        }
        if arguments.contains(uiTestUnavailableArgument) {
            recognizer.availabilityToReturn = .unavailable
            return recognizer
        }
        recognizer.autoDeliverAfterNanoseconds = uiTestDelay
        // Space consecutive partials apart so each is individually observable by a UI test's
        // own polling — delivering the whole sequence synchronously let SwiftUI coalesce every
        // intermediate value into one redraw showing only the last, making the live-partial-
        // transcript surface untestable. Only set here: `KueTests` cases construct this fake
        // directly and rely on the default (0 = deliver the whole sequence back-to-back).
        recognizer.interUpdateDelayNanoseconds = 500_000_000
        if arguments.contains(uiTestNoSpeechArgument) {
            recognizer.failureToDeliver = .noSpeechDetected
            return recognizer
        }
        if arguments.contains(uiTestFailureArgument) {
            recognizer.failureToDeliver = .recognitionFailed("simulated failure")
            return recognizer
        }
        if arguments.contains(uiTestLowConfidenceArgument) {
            recognizer.updatesToDeliver = [
                VoiceTranscriptionUpdate(text: "Fake Voice Low Confidence Text", isFinal: false),
                VoiceTranscriptionUpdate(text: "Fake Voice Low Confidence Text", isFinal: true),
            ]
            return recognizer
        }
        recognizer.updatesToDeliver = VoiceTranscriptionUpdate.fixtureInterviewSequence
        return recognizer
    }
}

extension VoiceTranscriptionUpdate {
    /// A deterministic "spoken event description" fixture, delivered as a growing sequence of
    /// partial updates (matching the real contract: each later update is the full transcript
    /// so far, not a fragment) ending in one final update.
    nonisolated static let fixtureInterviewSequence: [VoiceTranscriptionUpdate] = [
        VoiceTranscriptionUpdate(text: "Fake Voice", isFinal: false),
        VoiceTranscriptionUpdate(text: "Fake Voice Interview", isFinal: false),
        VoiceTranscriptionUpdate(text: "Fake Voice Interview Friday at 10", isFinal: false),
        VoiceTranscriptionUpdate(text: "Fake Voice Interview Friday at 10 AM", isFinal: true),
    ]
}
