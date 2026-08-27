//
//  OCRTextRecognizing.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. Requirement 13: Vision access behind a
//  dependency-injected protocol. `SystemOCRTextRecognizer` (real, Vision-backed) and
//  `FakeOCRTextRecognizer` (deterministic, requirement 44/48) are the only two conformers —
//  every view/service reaches recognition exclusively through this protocol, injected via
//  `OCREnvironment.swift`'s `\.ocrTextRecognizer`, never by constructing either directly.
//

import CoreGraphics

@MainActor
protocol OCRTextRecognizing {
    /// A pure capability check — requirement 37's "Vision unavailable" state. Never itself
    /// performs recognition or has side effects.
    func isAvailable() -> Bool

    /// `image` is already validated, downsampled, and orientation-corrected
    /// (`OCRImagePreprocessor.validateAndPrepare(data:)`) — this method only ever recognizes,
    /// it never re-validates or re-decodes.
    func recognizeText(in image: CGImage) async throws -> OCRRecognitionResult
}
