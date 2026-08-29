//
//  SystemVoiceAuthorizationChecker.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. The only file that reads/requests real microphone
//  or speech-recognition authorization — requirement 3/4.
//

import Foundation
import AVFAudio
import Speech

@MainActor
final class SystemVoiceAuthorizationChecker: VoiceAuthorizationChecking {
    func microphoneAuthorizationState() -> VoiceAuthorizationState {
        Self.map(AVAudioApplication.shared.recordPermission)
    }

    func speechAuthorizationState() -> VoiceAuthorizationState {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    func requestMicrophoneAuthorization() async -> VoiceAuthorizationState {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    continuation.resume(returning: granted ? .authorized : .denied)
                }
            }
        }
    }

    func requestSpeechAuthorization() async -> VoiceAuthorizationState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    continuation.resume(returning: Self.map(status))
                }
            }
        }
    }

    private static func map(_ permission: AVAudioApplication.recordPermission) -> VoiceAuthorizationState {
        switch permission {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .authorized
        @unknown default: return .unknown
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoiceAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }
}
