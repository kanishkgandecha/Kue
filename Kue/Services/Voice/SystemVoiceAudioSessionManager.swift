//
//  SystemVoiceAudioSessionManager.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. The only file that touches `AVAudioSession`
//  directly — requirement 3/17/18/19/20.
//

import Foundation
import AVFAudio

@MainActor
final class SystemVoiceAudioSessionManager: VoiceAudioSessionManaging {
    private var interruptionHandler: ((VoiceInterruptionEvent) -> Void)?
    private var routeChangeHandler: ((VoiceRouteChangeEvent) -> Void)?
    private var isObserving = false

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` — tuned for a single nearby speaker dictating, not music/ambient
            // capture; `.duckOthers` is requirement 19's "don't interfere unnecessarily with
            // other device audio" — anything else playing is lowered, not silenced/stopped
            // outright, and resumes at normal volume once Kue deactivates.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            throw VoiceRecognitionError.audioSessionConfigurationFailed(error.localizedDescription)
        }
    }

    func deactivate() {
        // Requirement 18/19 — `.notifyOthersOnDeactivation` lets whatever Kue ducked resume
        // immediately rather than waiting for its own next state change to notice.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func observeInterruptions(_ handler: @escaping (VoiceInterruptionEvent) -> Void) {
        interruptionHandler = handler
        ensureObserving()
    }

    func observeRouteChanges(_ handler: @escaping (VoiceRouteChangeEvent) -> Void) {
        routeChangeHandler = handler
        ensureObserving()
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        interruptionHandler = nil
        routeChangeHandler = nil
        isObserving = false
    }

    private func ensureObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let event = Self.mapInterruption(notification) else { return }
            Task { @MainActor in self.interruptionHandler?(event) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let event = Self.mapRouteChange(notification) else { return }
            Task { @MainActor in self.routeChangeHandler?(event) }
        }
    }

    nonisolated private static func mapInterruption(_ notification: Notification) -> VoiceInterruptionEvent? {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            return .ended(shouldResume: shouldResume)
        @unknown default:
            return nil
        }
    }

    nonisolated private static func mapRouteChange(_ notification: Notification) -> VoiceRouteChangeEvent? {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return nil }
        return VoiceRouteChangeEvent(reasonDescription: String(describing: reason))
    }
}
