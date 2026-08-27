//
//  SystemVoiceMicrophoneCapture.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. The only file that touches `AVAudioEngine`
//  directly — requirement 3/4.
//

import Foundation
import AVFAudio

@MainActor
final class SystemVoiceMicrophoneCapture: VoiceMicrophoneCapturing {
    private let engine = AVAudioEngine()
    private(set) var isCapturing = false

    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceRecognitionError.microphoneUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw VoiceRecognitionError.recordingStartFailed(error.localizedDescription)
        }
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }
}
