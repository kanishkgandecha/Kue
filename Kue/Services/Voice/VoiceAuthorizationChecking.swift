//
//  VoiceAuthorizationChecking.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 4/11/12/13/14: microphone and speech
//  authorization, checked and requested independently, behind their own dependency-injected
//  protocol — `SystemVoiceAuthorizationChecker` is the only file that imports `AVFAudio`'s
//  `AVAudioApplication` or `Speech`'s `SFSpeechRecognizer.authorizationStatus`/
//  `requestAuthorization` for permission purposes.
//

import Foundation

@MainActor
protocol VoiceAuthorizationChecking {
    /// Pure reads — requirement 12: never themselves request anything.
    func microphoneAuthorizationState() -> VoiceAuthorizationState
    func speechAuthorizationState() -> VoiceAuthorizationState

    /// Requirement 11 — only ever called from a deliberate "Start Recording" tap, after Kue's
    /// own contextual permission education is already on-screen; never from app launch or
    /// onboarding.
    func requestMicrophoneAuthorization() async -> VoiceAuthorizationState
    func requestSpeechAuthorization() async -> VoiceAuthorizationState
}
