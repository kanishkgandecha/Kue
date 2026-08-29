//
//  SystemOCRTextRecognizer.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. The one file in this app that imports Vision
//  and touches `VNImageRequestHandler`/`VNRecognizeTextRequest` directly — requirement 11/13/
//  14. Translates immediately to/from the Kue-owned value types in OCRKitTypes.swift; no
//  `VNRecognizedTextObservation` ever escapes this file.
//

import Foundation
import Vision

@MainActor
final class SystemOCRTextRecognizer: OCRTextRecognizing {
    /// Text recognition itself has no permission/eligibility gate the way Calendar or Apple
    /// Intelligence do — it's available on every iOS 26 device this app targets. Modeled as a
    /// real (if trivially `true`) check anyway so the DI seam has a genuine "unavailable" path
    /// a fake can exercise deterministically (requirement 37), rather than that state being
    /// unreachable outside this one file.
    func isAvailable() -> Bool { true }

    /// Requirement 12: `.accurate` recognition level (favors correctness over raw speed —
    /// appropriate for a one-shot, user-reviewed import rather than a live/continuous scan),
    /// language correction off (event text — titles, dates, place names — isn't prose an
    /// autocorrect-style language model should be "fixing"), and language set pinned to the
    /// device's own preferred languages so behavior doesn't silently shift with unrelated
    /// system state changes mid-session.
    func recognizeText(in image: CGImage) async throws -> OCRRecognitionResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = Locale.preferredLanguages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRRecognitionError.recognitionFailed(error.localizedDescription)
        }

        let observations = request.results ?? []
        // Requirement 16/46 "line ordering" — `VNRecognizeTextRequest.results` is already
        // returned in reading order (top-to-bottom, matching how the request itself scans the
        // image); preserved here verbatim, never re-sorted.
        let lines: [OCRTextLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextLine(text: candidate.string, confidence: candidate.confidence)
        }

        guard !lines.isEmpty else { throw OCRRecognitionError.noTextFound }

        let fullText = lines.map(\.text).joined(separator: "\n")
        let confidence = OCRConfidence.aggregate(lineConfidences: lines.map(\.confidence))
        return OCRRecognitionResult(fullText: fullText, lines: lines, confidence: confidence)
    }
}
