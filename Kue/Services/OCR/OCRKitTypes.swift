//
//  OCRKitTypes.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. See docs/19-screenshot-ocr-input.md
//  "Vision abstraction". Requirement 14/15: Vision framework types stay at the integration
//  boundary — everything in this file is a plain, Kue-owned value type. Nothing outside
//  SystemOCRTextRecognizer.swift ever imports Vision or names `VNRecognizeTextRequest`/
//  `VNRecognizedTextObservation`/`VNImageRequestHandler` directly.
//

import Foundation

/// Requirement 9/6 — the only encoded formats Kue will attempt to recognize. Anything else is
/// `OCRImageValidationError.unsupportedFormat`, checked from the encoded data's own type
/// identifier before any pixel decode (requirement 10).
enum OCRImageFormat: Equatable {
    case jpeg
    case png
    case heic
}

/// Requirement 9 — every numeric safety ceiling this phase enforces, in one place so they're
/// easy to audit and to reference from tests. All four decode-time checks
/// (`maxDecodedDimension`/`maxPixelCount`) are evaluated from the encoded image's *properties*
/// (`CGImageSource`), never by first decoding full-resolution pixels — requirement 10.
enum OCRImageLimits {
    /// Encoded file size, checked against `Data.count` before `CGImageSourceCreateWithData` is
    /// even called. 25 MB comfortably covers a real photo or screenshot (typically well under
    /// 10 MB) while rejecting anything pathological.
    static let maxEncodedByteSize = 25_000_000
    /// Per-side decoded pixel dimension, read from `CGImageSourceCopyPropertiesAtIndex` (no
    /// full decode). Covers the largest current iPhone camera output with headroom.
    static let maxDecodedDimension = 8_192
    /// `width * height`, same source as `maxDecodedDimension` — catches a decode bomb whose
    /// individual dimensions each pass but whose product doesn't (e.g. an extreme aspect
    /// ratio), which a per-side check alone wouldn't.
    static let maxPixelCount = 50_000_000
    /// The long-edge size Vision actually receives, *after* downsampling
    /// (`OCRImagePreprocessor`) — requirement 8/9's "recognition memory use" bound. A CGImage
    /// at this size is at most ~4.2M pixels; Vision's own working buffers stay bounded
    /// regardless of how large the original photo was.
    static let recognitionMaxDimension = 2_048
    static let acceptedFormats: Set<OCRImageFormat> = [.jpeg, .png, .heic]
}

/// Requirement 6/9/37 — every way `OCRImagePreprocessor.validateAndPrepare(data:)` can reject
/// an input, each with its own specific, actionable message (docs/13-error-handling.md).
enum OCRImageValidationError: LocalizedError, Equatable {
    case unsupportedFormat
    case malformedData
    case excessiveEncodedSize
    case excessiveDimensions
    case excessivePixelCount
    case orientationCorrectionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "That file isn't a supported image format (JPEG, PNG, or HEIC) — try a different photo."
        case .malformedData:
            return "That image couldn't be read — it may be damaged. Try a different photo."
        case .excessiveEncodedSize:
            return "That image is too large to process. Try a smaller photo or a cropped screenshot."
        case .excessiveDimensions, .excessivePixelCount:
            return "That image's dimensions are too large to process. Try a smaller photo or a cropped screenshot."
        case .orientationCorrectionFailed:
            return "That image's orientation couldn't be read. Try a different photo."
        }
    }
}

/// Requirement 16 — one recognized line, with per-line confidence (requirement 16/46
/// "confidence aggregation" operates over these).
struct OCRTextLine: Equatable {
    var text: String
    /// Vision's own `VNRecognizedText.confidence`, 0...1 — the only place a raw Vision value
    /// crosses this boundary, already converted to a plain `Float`.
    var confidence: Float
}

/// Requirement 17 — deterministic, three-level confidence a view can key an actionable warning
/// off of, never itself a reason to discard text (requirement 18).
enum OCRConfidence: Comparable {
    case low
    case medium
    case high

    /// Requirement 46 "confidence aggregation" — the mean of every recognized line's own
    /// confidence, bucketed at fixed, documented thresholds (docs/19-screenshot-ocr-input.md).
    /// Empty input (no lines at all) aggregates to `.low` — never silently treated as
    /// confident just because there was nothing to average.
    static func aggregate(lineConfidences: [Float]) -> OCRConfidence {
        guard !lineConfidences.isEmpty else { return .low }
        let mean = lineConfidences.reduce(0, +) / Float(lineConfidences.count)
        if mean >= 0.75 { return .high }
        if mean >= 0.4 { return .medium }
        return .low
    }

    var warningMessage: String? {
        switch self {
        case .high: return nil
        case .medium: return "Some of this text may not be fully accurate — please review it."
        case .low: return "This text may be inaccurate — please review it carefully before continuing."
        }
    }
}

/// Requirement 40/41/42 — a tiny, pure generation counter so "is this async result still the
/// one the user is waiting for" is a testable fact rather than logic embedded directly in
/// SwiftUI view state. `OCRImportView` calls `advance()` every time it starts a new unit of
/// work (a new image selection, a reset, or a cancel) and only applies a completed task's
/// result when `isCurrent(_:)` still holds for the generation that task captured at its own
/// start — a superseded run can never clobber newer state, and starting new work is itself
/// what invalidates whatever's still in flight (requirement 40: rapid repeated actions can't
/// pile up applying stale results).
struct OCRRequestGeneration: Equatable {
    private(set) var value = 0

    @discardableResult
    mutating func advance() -> Int {
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool { generation == value }
}

/// Requirement 15/16 — everything the review screen and the rest of the app ever see from a
/// recognition pass. `fullText` is lines joined in reading order (requirement 46 "line
/// ordering") — top-to-bottom, matching `VNRecognizedTextObservation`'s own already-reading-
/// order array, which `SystemOCRTextRecognizer` preserves without re-sorting.
struct OCRRecognitionResult: Equatable {
    var fullText: String
    var lines: [OCRTextLine]
    var confidence: OCRConfidence
}

/// Requirement 37 — every way recognition itself can fail, distinct from image validation
/// (`OCRImageValidationError`, which never reaches Vision at all) and from "recognized
/// successfully but found nothing" (`.noTextFound`, requirement 18 — a real, distinct outcome,
/// not folded into a generic failure).
enum OCRRecognitionError: LocalizedError, Equatable {
    case unavailable
    case noTextFound
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device text recognition isn't available right now — add this event manually instead."
        case .noTextFound:
            return "No text was found in that image. Try a clearer photo, or add this event manually."
        case .recognitionFailed(let reason):
            return "Couldn't read text from that image: \(reason)"
        }
    }
}
