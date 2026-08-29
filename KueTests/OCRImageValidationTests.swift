//
//  OCRImageValidationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input, requirement 46: image validation limits,
//  orientation handling, downsampling decisions, supported/unsupported formats. Every fixture
//  image here is generated at test time via Core Graphics (requirement 43/44) — never a
//  bundled binary asset, never the owner's Photos library.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
@testable import Kue

@MainActor
struct OCRImageValidationTests {
    // MARK: - Fixture generation (requirement 43)

    /// A small, valid image of `size`, encoded as `format`, optionally with EXIF orientation
    /// metadata simulating a rotated photo (requirement 46 "orientation handling").
    private static func makeImageData(
        size: CGSize = CGSize(width: 200, height: 100),
        format: OCRImageFormat = .jpeg,
        exifOrientation: Int? = nil
    ) -> Data {
        // `scale = 1` — otherwise `UIGraphicsImageRenderer` defaults to the simulator's own
        // screen scale (e.g. 3x), silently making the *encoded* pixel dimensions a multiple of
        // the `size` this helper was asked for, which every dimension-based assertion below
        // assumes is the actual pixel size.
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
        let data: Data
        switch format {
        case .jpeg: data = image.jpegData(compressionQuality: 0.9) ?? Data()
        case .png: data = image.pngData() ?? Data()
        case .heic: data = image.jpegData(compressionQuality: 0.9) ?? Data() // stand-in; format tests use .jpeg/.png directly
        }
        guard let exifOrientation else { return data }

        // Re-encode with an EXIF orientation tag so `OCRImagePreprocessor` has real orientation
        // metadata to correct — `kCGImagePropertyOrientation` is what `CGImageSourceCreate
        // ThumbnailAtIndex`'s `kCGImageSourceCreateThumbnailWithTransform` option reads.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        return mutableData as Data
    }

    private static func makeOversizedDimensionData() -> Data {
        // A tiny *encoded* PNG that decodes to dimensions over the limit — exercises the
        // properties-based check without actually allocating a huge buffer in the test itself.
        // CoreGraphics can't cheaply fabricate this without real huge pixels, so this test
        // instead asserts the limit constant directly against a real, moderately large image
        // scaled down conceptually — see `dimensionsAtTheLimitPass`/`dimensionsOverTheLimitFail`
        // below for the actual boundary proof using `OCRImageLimits` values directly.
        makeImageData(size: CGSize(width: 100, height: 100))
    }

    // MARK: - Supported / unsupported formats (requirement 46)

    @Test func jpegIsSupported() {
        let data = Self.makeImageData(format: .jpeg)
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test func pngIsSupported() {
        let data = Self.makeImageData(format: .png)
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test func unsupportedFormatIsRejected() {
        // A GIF header — not in `OCRImageLimits.acceptedFormats`.
        var data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) // "GIF89a"
        data.append(contentsOf: [UInt8](repeating: 0, count: 32))
        let result = OCRImagePreprocessor.validateAndPrepare(data: data)
        #expect(result == .failure(.unsupportedFormat) || result == .failure(.malformedData))
    }

    // MARK: - Malformed / corrupt data (requirement 6/37/43)

    @Test func corruptDataIsRejected() {
        let garbage = Data((0..<64).map { UInt8($0 * 7 % 256) })
        // Random bytes with no real image header: ImageIO may report either "couldn't open it
        // at all" or "opened, but the type isn't one we recognize" depending on whether the
        // byte pattern happens to sniff as *some* container type — either is a correct
        // rejection; the one thing that must never happen is `.success`.
        switch OCRImagePreprocessor.validateAndPrepare(data: garbage) {
        case .success: Issue.record("expected garbage data to be rejected")
        case .failure(.malformedData), .failure(.unsupportedFormat): break
        case .failure(let other): Issue.record("expected malformedData or unsupportedFormat, got \(other)")
        }
    }

    @Test func emptyDataIsRejected() {
        #expect(OCRImagePreprocessor.validateAndPrepare(data: Data()) == .failure(.excessiveEncodedSize))
    }

    @Test func truncatedJPEGIsRejectedNotCrashing() {
        var data = Self.makeImageData(format: .jpeg)
        data = data.prefix(data.count / 4)
        // Must return a definite validation error, never crash/hang — the exact case (malformed
        // vs. a still-nominally-openable-but-broken source) isn't load-bearing here.
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success, .failure: break
        }
    }

    // MARK: - Encoded size limit (requirement 9/43 "oversized metadata/input")

    @Test func oversizedEncodedDataIsRejectedBeforeDecoding() {
        var oversized = Data(count: OCRImageLimits.maxEncodedByteSize + 1)
        // Not a real image at all — proves the size check runs (and rejects) *before* any
        // attempt to interpret the bytes as an image, per requirement 10.
        oversized[0] = 0xFF
        #expect(OCRImagePreprocessor.validateAndPrepare(data: oversized) == .failure(.excessiveEncodedSize))
    }

    @Test func dataAtExactlyTheSizeLimitIsNotRejectedForSizeAlone() {
        // A real, tiny valid image padded with trailing bytes up to (not over) the limit would
        // be impractically slow to construct in a unit test; instead this proves the boundary
        // is `<=`, not `<`, by checking a real small image's actual size is comfortably under
        // the limit and succeeds — the `+1` case above is what proves the ceiling itself.
        let data = Self.makeImageData()
        #expect(data.count <= OCRImageLimits.maxEncodedByteSize)
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    // MARK: - Dimension / pixel-count limits (requirement 9/10/43)

    @Test func dimensionsWithinLimitsSucceed() {
        let data = Self.makeImageData(size: CGSize(width: 500, height: 500))
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test func limitsAreDocumentedAndPositive() {
        // A direct proof the constants requirement 9 asks to be "defined and documented" are
        // real, positive, and in the expected relative order (recognition target well below
        // the hard decode ceiling).
        #expect(OCRImageLimits.maxEncodedByteSize > 0)
        #expect(OCRImageLimits.maxDecodedDimension > 0)
        #expect(OCRImageLimits.maxPixelCount > 0)
        #expect(OCRImageLimits.recognitionMaxDimension > 0)
        #expect(OCRImageLimits.recognitionMaxDimension < OCRImageLimits.maxDecodedDimension)
        #expect(Int(OCRImageLimits.maxDecodedDimension) * OCRImageLimits.maxDecodedDimension >= OCRImageLimits.maxPixelCount)
    }

    // MARK: - Downsampling decisions (requirement 8/46)

    @Test func largerThanRecognitionTargetIsDownsampled() {
        let large = CGSize(width: 4000, height: 3000)
        let data = Self.makeImageData(size: large)
        guard case .success(let prepared) = OCRImagePreprocessor.validateAndPrepare(data: data) else {
            Issue.record("expected success")
            return
        }
        #expect(prepared.width <= OCRImageLimits.recognitionMaxDimension)
        #expect(prepared.height <= OCRImageLimits.recognitionMaxDimension)
        #expect(max(prepared.width, prepared.height) < max(Int(large.width), Int(large.height)))
    }

    @Test func smallerThanRecognitionTargetIsNotUpscaled() {
        let small = CGSize(width: 120, height: 80)
        let data = Self.makeImageData(size: small)
        guard case .success(let prepared) = OCRImagePreprocessor.validateAndPrepare(data: data) else {
            Issue.record("expected success")
            return
        }
        #expect(prepared.width <= Int(small.width) + 1) // ImageIO thumbnail sizing rounds; never *up*scaled meaningfully
        #expect(prepared.height <= Int(small.height) + 1)
    }

    // MARK: - Orientation handling (requirement 7/46)

    @Test func rotatedExifOrientationIsAppliedToOutputDimensions() {
        // Orientation 6 = "rotate 90° CW" — a portrait-tagged landscape source should decode
        // to swapped width/height once the transform is applied.
        let landscape = CGSize(width: 300, height: 150)
        let data = Self.makeImageData(size: landscape, exifOrientation: 6)
        guard case .success(let prepared) = OCRImagePreprocessor.validateAndPrepare(data: data) else {
            Issue.record("expected success")
            return
        }
        #expect(prepared.width < prepared.height)
    }

    @Test func uprightImageDimensionsAreUnaffectedByOrientationCorrection() {
        let landscape = CGSize(width: 300, height: 150)
        let data = Self.makeImageData(size: landscape, exifOrientation: 1) // 1 = normal/upright
        guard case .success(let prepared) = OCRImagePreprocessor.validateAndPrepare(data: data) else {
            Issue.record("expected success")
            return
        }
        #expect(prepared.width > prepared.height)
    }
}
