//
//  OCRImagePreprocessor.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. See docs/19-screenshot-ocr-input.md
//  "Validation and preprocessing". Pure, synchronous, deterministic — no Vision, no PhotosUI.
//  Every check runs against the encoded data or the image's own *properties* before any full
//  pixel decode happens (requirement 10) — `CGImageSourceCopyPropertiesAtIndex` reads
//  dimensions from the container's header, not by decoding the image.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum OCRImagePreprocessor {
    /// Requirement 6/7/8/9/10 in one deterministic pipeline: reject anything unsupported,
    /// malformed, or over any documented limit *before* decoding full-resolution pixels: then
    /// decode a single downsampled, orientation-corrected `CGImage` sized for recognition
    /// (never the original full resolution) via `CGImageSourceCreateThumbnailAtIndex`, which
    /// applies both the downsample and the EXIF-orientation transform in the same call.
    static func validateAndPrepare(data: Data) -> Result<CGImage, OCRImageValidationError> {
        // Requirement 9/10 — encoded size, checked before touching ImageIO at all.
        guard data.count > 0, data.count <= OCRImageLimits.maxEncodedByteSize else {
            return .failure(.excessiveEncodedSize)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return .failure(.malformedData)
        }

        guard let format = format(of: source), OCRImageLimits.acceptedFormats.contains(format) else {
            return .failure(.unsupportedFormat)
        }

        // Requirement 10 — dimensions read from properties, no pixel decode yet.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return .failure(.malformedData)
        }

        guard width <= OCRImageLimits.maxDecodedDimension, height <= OCRImageLimits.maxDecodedDimension else {
            return .failure(.excessiveDimensions)
        }
        guard width * height <= OCRImageLimits.maxPixelCount else {
            return .failure(.excessivePixelCount)
        }

        // Requirement 7/8 — one bounded decode: downsamples to `recognitionMaxDimension` on
        // the long edge (requirement 8) and bakes the EXIF orientation into the output pixels
        // (`kCGImageSourceCreateThumbnailWithTransform`, requirement 7) so nothing downstream
        // ever has to reason about orientation separately. `CreateThumbnailFromImageAlways`
        // means a small source still gets this same orientation-correcting pass, not just
        // large ones — orientation correctness never depends on whether downsampling actually
        // did anything.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: OCRImageLimits.recognitionMaxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let prepared = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return .failure(.orientationCorrectionFailed)
        }

        return .success(prepared)
    }

    private static func format(of source: CGImageSource) -> OCRImageFormat? {
        guard let uti = CGImageSourceGetType(source) as String? else { return nil }
        switch UTType(uti) {
        case UTType.jpeg: return .jpeg
        case UTType.png: return .png
        case UTType.heic: return .heic
        default: return nil
        }
    }
}
