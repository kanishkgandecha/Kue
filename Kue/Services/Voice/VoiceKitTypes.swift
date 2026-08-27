//
//  VoiceKitTypes.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. See docs/20-voice-input.md "Abstraction".
//  Requirement 3/5: Apple framework types (`AVAudioSession`, `AVAudioEngine`, `SFSpeechRecognizer`,
//  etc.) stay at the integration boundary — everything in this file is a plain, Kue-owned value
//  type. Nothing outside `SystemVoiceAudioSessionManager`/`SystemVoiceMicrophoneCapture`/
//  `SystemVoiceSpeechRecognizer` ever imports `Speech` or names an `SFSpeechRecognizer`/
//  `SFSpeechRecognitionTask`/`AVAudioSession` directly.
//

import Foundation

// MARK: - Authorization (requirement 5/13/14)

/// Requirement 14 — every state Kue distinguishes, for *both* microphone and speech
/// authorization independently (requirement 13). Mirrors `CalendarAuthorizationState`'s shape:
/// `.restricted`/`.unavailable` are real states this enum supports even though the underlying
/// system API a given real checker reads from may never actually produce every one of them —
/// keeping them here means a fake can still exercise those UI states deterministically
/// (requirement 59/61), and the enum stays forward-compatible with a future API that does.
enum VoiceAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
    case unknown

    var isAuthorized: Bool { self == .authorized }
    /// Requirement 16 — denied and restricted both mean "the user (or a policy) has already
    /// decided," so a Settings link is the only remaining recovery; `.restricted` additionally
    /// means Settings itself can't change it (parental controls/MDM), which the row/message
    /// built from this state must say explicitly rather than offering a broken link.
    var canOpenSettingsToChange: Bool { self == .denied }
}

/// Requirement 13/15 — both permissions tracked independently; `VoiceInputCoordinator` reads
/// this pair together to decide exactly which capability (or both) is unavailable and why.
struct VoiceAuthorizationSnapshot: Equatable {
    var microphone: VoiceAuthorizationState
    var speech: VoiceAuthorizationState

    var isFullyAuthorized: Bool { microphone.isAuthorized && speech.isAuthorized }

    /// Requirement 15 — a specific, correct sentence naming exactly which capability (or both)
    /// remains unavailable, never a generic "permission denied."
    var blockingExplanation: String? {
        let microphoneBlocked = !microphone.isAuthorized
        let speechBlocked = !speech.isAuthorized
        switch (microphoneBlocked, speechBlocked) {
        case (false, false):
            return nil
        case (true, false):
            return microphone.explanation(capability: "Microphone")
        case (false, true):
            return speech.explanation(capability: "Speech Recognition")
        case (true, true):
            return "Kue needs both Microphone and Speech Recognition access to use Voice input. " + microphone.explanation(capability: "Microphone", short: true)
        }
    }
}

private extension VoiceAuthorizationState {
    func explanation(capability: String, short: Bool = false) -> String {
        switch self {
        case .denied:
            return short ? "Turn both on in Settings." : "\(capability) access is off. Turn it on in Settings to use Voice input."
        case .restricted:
            return short ? "\(capability) is restricted on this device." : "\(capability) access is restricted on this device (e.g. by Screen Time) and can't be changed here."
        case .unavailable:
            return "\(capability) isn't available on this device."
        case .notDetermined, .authorized, .unknown:
            return "\(capability) access isn't available right now."
        }
    }
}

// MARK: - Recognizer availability (requirement 7/8/9/10)

/// Separate from authorization: even with both permissions granted, on-device recognition can
/// be unsupported for the current locale/device, or the recognizer can be transiently
/// unavailable. Requirement 10: Kue never falls back to network recognition, so "on-device
/// isn't supported" and "recognizer unavailable" are both, for Kue's purposes, simply
/// unavailable — there is no third "use the network instead" state anywhere in this enum.
enum VoiceRecognizerAvailability: Equatable {
    case availableOnDevice
    case onDeviceUnsupported
    case unavailable

    var canRecord: Bool { self == .availableOnDevice }

    var explanation: String? {
        switch self {
        case .availableOnDevice:
            return nil
        case .onDeviceUnsupported:
            return "On-device speech recognition isn't supported for this language on this device. Kue never sends audio to a server, so voice input isn't available right now — try typing, Scan Screenshot, or check again later."
        case .unavailable:
            return "Speech recognition isn't available right now — try typing, Scan Screenshot, or check again later."
        }
    }
}

// MARK: - Recording state (requirement 5/23/24)

enum VoiceRecordingPhase: Equatable {
    case idle
    case recording
    case finalizing
    case reviewing
    case noSpeechDetected
    case error(String)
}

// MARK: - Transcription (requirement 5/16/31)

/// Requirement 31 — each update already carries the *complete* current transcript (matching
/// `SFSpeechRecognitionResult.bestTranscription.formattedString`'s own always-whole-so-far
/// contract), never a fragment to append — so applying the latest update is always a plain
/// replacement, which is what keeps ordering trivially correct as long as stale/superseded
/// updates are discarded (`VoiceRequestGeneration`) before being applied.
struct VoiceTranscriptionUpdate: Equatable {
    var text: String
    var isFinal: Bool
}

/// Requirement 51 "low-confidence transcription where available" — mirrors `OCRConfidence`'s
/// shape/thresholds; kept as its own type (not a shared generic) so each phase's confidence
/// semantics stay independently documented, matching how `CalendarOperationError` and
/// `OCRRecognitionError` are each their own type rather than a shared "APIError."
enum VoiceConfidence: Comparable {
    case low, medium, high

    static func aggregate(segmentConfidences: [Float]) -> VoiceConfidence {
        guard !segmentConfidences.isEmpty else { return .low }
        let mean = segmentConfidences.reduce(0, +) / Float(segmentConfidences.count)
        if mean >= 0.75 { return .high }
        if mean >= 0.4 { return .medium }
        return .low
    }

    var warningMessage: String? {
        switch self {
        case .high: return nil
        case .medium: return "Some of this transcription may not be fully accurate — please review it."
        case .low: return "This transcription may be inaccurate — please review it carefully before continuing."
        }
    }
}

struct VoiceRecognitionResult: Equatable {
    var text: String
    var confidence: VoiceConfidence
}

// MARK: - Errors (requirement 51)

enum VoiceRecognitionError: LocalizedError, Equatable {
    case audioSessionConfigurationFailed(String)
    case microphoneUnavailable
    case recordingStartFailed(String)
    case interrupted
    case recognitionCancelled
    case recognitionFailed(String)
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .audioSessionConfigurationFailed:
            return "Couldn't set up audio for recording. Try again in a moment."
        case .microphoneUnavailable:
            return "The microphone isn't available right now — it may be in use by another app."
        case .recordingStartFailed:
            return "Couldn't start recording. Try again."
        case .interrupted:
            return "Recording was interrupted."
        case .recognitionCancelled:
            return "Recognition was cancelled."
        case .recognitionFailed:
            return "Couldn't transcribe that recording. Try again."
        case .noSpeechDetected:
            return "No speech was detected. Try again, or add this event manually."
        }
    }
}

// MARK: - Interruption / route change (requirement 3/18/20)

/// Requirement 3 — a Kue-owned stand-in for `AVAudioSession.InterruptionType` so the
/// coordinator never has to import `AVFoundation` to react to one.
enum VoiceInterruptionEvent: Equatable {
    case began
    case ended(shouldResume: Bool)
}

/// A Kue-owned stand-in for `AVAudioSession.RouteChangeReason` — the coordinator only ever
/// needs to know *that* the route changed during an active recording (requirement 20: handled
/// deterministically by stopping and finalizing, never by trying to reason about every possible
/// specific reason), not the full reason taxonomy.
struct VoiceRouteChangeEvent: Equatable {
    var reasonDescription: String
}

// MARK: - Cancellation / stale-result guard (requirement 53/54/55)

/// Requirement 21/22/53/54 — a tiny, pure generation counter, the same shape
/// `OCRRequestGeneration` (Kue 2.0 Phase 5) established: `advance()` on every new unit of work
/// (starting to record, retrying, cancelling), `isCurrent(_:)` checked before any async
/// callback (a partial/final transcription update, an error) is applied. A second "Start
/// Recording" tap while one session is already active is itself prevented at the coordinator
/// level (requirement 21/22), independent of this guard, which exists for the *async result*
/// side of that same problem — a callback from a session that's already been superseded or
/// cancelled must never mutate state a newer session owns.
struct VoiceRequestGeneration: Equatable {
    private(set) var value = 0

    @discardableResult
    mutating func advance() -> Int {
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool { generation == value }
}

// MARK: - Limits (requirement 26/28)

/// Requirement 26/28 — documented, bounded limits (docs/20-voice-input.md has the full
/// rationale). Both exist for the same underlying reason: requirement 29 — Kue must never run
/// an indefinite background recording session.
enum VoiceLimits {
    /// A spoken event description ("Interview with Acme Friday at 10 in the downtown office")
    /// comfortably fits in well under a minute; 60 seconds gives generous headroom for a
    /// slower speaker or a more detailed description while still bounding worst-case audio
    /// buffering/recognition memory and guaranteeing the session eventually ends on its own.
    static let maxRecordingDuration: TimeInterval = 60
    /// If the recognized transcript hasn't changed for this long while still recording, the
    /// user has most likely stopped speaking (or never started) — stop automatically rather
    /// than waiting indefinitely for speech that isn't coming.
    static let silenceTimeout: TimeInterval = 5
}
