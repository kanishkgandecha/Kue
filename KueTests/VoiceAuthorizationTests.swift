//
//  VoiceAuthorizationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 6 — On-Device Voice Input, requirement 61: every authorization-state
//  combination, no permission request before contextual education, on-device availability,
//  and prevention of network fallback. `FakeVoiceAuthorizationChecker`/
//  `FakeVoiceSpeechRecognizer` only — never real `AVAudioApplication`/`Speech`.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct VoiceAuthorizationTests {
    // MARK: - Every authorization-state combination (requirement 14/15/61)

    @Test(arguments: [
        VoiceAuthorizationState.notDetermined, .authorized, .denied, .restricted, .unavailable, .unknown,
    ])
    func everyMicrophoneStateIsReportedDistinctly(_ state: VoiceAuthorizationState) {
        let fake = FakeVoiceAuthorizationChecker()
        fake.microphoneStateToReturn = state
        #expect(fake.microphoneAuthorizationState() == state)
    }

    @Test(arguments: [
        VoiceAuthorizationState.notDetermined, .authorized, .denied, .restricted, .unavailable, .unknown,
    ])
    func everySpeechStateIsReportedDistinctly(_ state: VoiceAuthorizationState) {
        let fake = FakeVoiceAuthorizationChecker()
        fake.speechStateToReturn = state
        #expect(fake.speechAuthorizationState() == state)
    }

    @Test func bothAuthorizedIsFullyAuthorized() {
        let snapshot = VoiceAuthorizationSnapshot(microphone: .authorized, speech: .authorized)
        #expect(snapshot.isFullyAuthorized)
        #expect(snapshot.blockingExplanation == nil)
    }

    @Test func microphoneDeniedAloneNamesOnlyMicrophone() {
        let snapshot = VoiceAuthorizationSnapshot(microphone: .denied, speech: .authorized)
        #expect(!snapshot.isFullyAuthorized)
        let explanation = try! #require(snapshot.blockingExplanation)
        #expect(explanation.contains("Microphone"))
        #expect(!explanation.contains("Speech Recognition"))
    }

    @Test func speechDeniedAloneNamesOnlySpeech() {
        let snapshot = VoiceAuthorizationSnapshot(microphone: .authorized, speech: .denied)
        #expect(!snapshot.isFullyAuthorized)
        let explanation = try! #require(snapshot.blockingExplanation)
        #expect(explanation.contains("Speech Recognition"))
        #expect(!explanation.contains("Microphone access"))
    }

    @Test func bothDeniedNamesBoth() {
        let snapshot = VoiceAuthorizationSnapshot(microphone: .denied, speech: .denied)
        let explanation = try! #require(snapshot.blockingExplanation)
        #expect(explanation.contains("Microphone"))
        #expect(explanation.contains("Speech Recognition"))
    }

    @Test func onlyDeniedCanOpenSettingsRestrictedCannot() {
        #expect(VoiceAuthorizationState.denied.canOpenSettingsToChange)
        #expect(!VoiceAuthorizationState.restricted.canOpenSettingsToChange)
        #expect(!VoiceAuthorizationState.notDetermined.canOpenSettingsToChange)
        #expect(!VoiceAuthorizationState.unavailable.canOpenSettingsToChange)
    }

    // MARK: - No permission request before contextual education (requirement 11/12)

    @Test func readingAuthorizationStateNeverRequestsIt() {
        let fake = FakeVoiceAuthorizationChecker()
        _ = fake.microphoneAuthorizationState()
        _ = fake.speechAuthorizationState()
        #expect(fake.microphoneRequestCount == 0)
        #expect(fake.speechRequestCount == 0)
    }

    @Test func startingRecordingIsTheOnlyThingThatRequestsPermission() async {
        let authorizationChecker = FakeVoiceAuthorizationChecker()
        let coordinator = VoiceInputCoordinator(
            authorizationChecker: authorizationChecker,
            audioSessionManager: FakeVoiceAudioSessionManager(),
            microphoneCapture: FakeVoiceMicrophoneCapture(),
            speechRecognizer: FakeVoiceSpeechRecognizer()
        )
        #expect(authorizationChecker.microphoneRequestCount == 0)
        await coordinator.startRecording()
        #expect(authorizationChecker.microphoneRequestCount == 1)
        #expect(authorizationChecker.speechRequestCount == 1)
    }

    // MARK: - On-device availability (requirement 7/8/61)

    @Test func onDeviceAvailableCanRecord() {
        #expect(VoiceRecognizerAvailability.availableOnDevice.canRecord)
    }

    @Test func onDeviceUnsupportedCannotRecord() {
        #expect(!VoiceRecognizerAvailability.onDeviceUnsupported.canRecord)
        #expect(VoiceRecognizerAvailability.onDeviceUnsupported.explanation != nil)
    }

    @Test func unavailableCannotRecord() {
        #expect(!VoiceRecognizerAvailability.unavailable.canRecord)
        #expect(VoiceRecognizerAvailability.unavailable.explanation != nil)
    }

    // MARK: - Prevention of network fallback (requirement 9/10/61)

    @Test func thereIsNoRecognizerAvailabilityCaseThatPermitsRecordingWithoutOnDeviceSupport() {
        // Requirement 10 — structurally, `canRecord` is true for exactly one case,
        // `.availableOnDevice`; there is no "use the network instead" state anywhere in the
        // type at all for `startRecording()` to ever fall through to.
        let allCases: [VoiceRecognizerAvailability] = [.availableOnDevice, .onDeviceUnsupported, .unavailable]
        let recordable = allCases.filter(\.canRecord)
        #expect(recordable == [.availableOnDevice])
    }

    @Test func startRecordingRefusesWhenOnDeviceRecognitionIsUnsupported() async {
        let speechRecognizer = FakeVoiceSpeechRecognizer()
        speechRecognizer.availabilityToReturn = .onDeviceUnsupported
        let coordinator = VoiceInputCoordinator(
            authorizationChecker: FakeVoiceAuthorizationChecker(),
            audioSessionManager: FakeVoiceAudioSessionManager(),
            microphoneCapture: FakeVoiceMicrophoneCapture(),
            speechRecognizer: speechRecognizer
        )
        await coordinator.startRecording()
        #expect(speechRecognizer.startCallCount == 0)
        if case .error = coordinator.phase {} else {
            Issue.record("expected .error, got \(coordinator.phase)")
        }
    }
}
