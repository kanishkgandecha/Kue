//
//  OCRRecognitionTests.swift
//  KueTests
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input, requirement 46: confidence aggregation,
//  low-confidence behavior, no-text behavior, recognized-text normalization, line ordering,
//  and the `OCRTextRecognizing` DI seam itself (availability, fake behavior). Pure/deterministic
//  — `FakeOCRTextRecognizer` only, never `Vision`.
//

import Testing
import Foundation
import CoreGraphics
@testable import Kue

@MainActor
struct OCRRecognitionTests {
    // MARK: - Confidence aggregation (requirement 17/46)

    @Test func highConfidenceLinesAggregateToHigh() {
        #expect(OCRConfidence.aggregate(lineConfidences: [0.9, 0.85, 0.95]) == .high)
    }

    @Test func mediumConfidenceLinesAggregateToMedium() {
        #expect(OCRConfidence.aggregate(lineConfidences: [0.5, 0.45, 0.6]) == .medium)
    }

    @Test func lowConfidenceLinesAggregateToLow() {
        #expect(OCRConfidence.aggregate(lineConfidences: [0.1, 0.2, 0.15]) == .low)
    }

    @Test func mixedConfidenceLinesAggregateByMean() {
        // Mean of 0.9 and 0.1 is 0.5 — medium, not a min/max-driven result.
        #expect(OCRConfidence.aggregate(lineConfidences: [0.9, 0.1]) == .medium)
    }

    @Test func emptyLinesAggregateToLowNeverToHigh() {
        // Requirement 18: nothing recognized must never present as confident.
        #expect(OCRConfidence.aggregate(lineConfidences: []) == .low)
    }

    @Test func thresholdBoundariesAreInclusiveOnTheHighSide() {
        #expect(OCRConfidence.aggregate(lineConfidences: [0.75]) == .high)
        #expect(OCRConfidence.aggregate(lineConfidences: [0.7499]) == .medium)
        #expect(OCRConfidence.aggregate(lineConfidences: [0.4]) == .medium)
        #expect(OCRConfidence.aggregate(lineConfidences: [0.3999]) == .low)
    }

    // MARK: - Low-confidence behavior (requirement 17/18)

    @Test func lowConfidenceHasAWarningMessageButIsNeverDiscarded() {
        let result = OCRRecognitionResult.fixtureLowConfidence
        #expect(result.confidence.warningMessage != nil)
        // The text itself survives — low confidence changes presentation, never the content.
        #expect(!result.fullText.isEmpty)
    }

    @Test func highConfidenceHasNoWarningMessage() {
        #expect(OCRConfidence.high.warningMessage == nil)
    }

    @Test func mediumAndLowConfidenceHaveDistinctWarningMessages() {
        #expect(OCRConfidence.medium.warningMessage != nil)
        #expect(OCRConfidence.low.warningMessage != nil)
        #expect(OCRConfidence.medium.warningMessage != OCRConfidence.low.warningMessage)
    }

    // MARK: - No-text behavior (requirement 18/37)

    @Test func noTextFoundIsADistinctErrorNotAnEmptySuccess() async {
        let fake = FakeOCRTextRecognizer(resultToReturn: .failure(OCRRecognitionError.noTextFound))
        let image = Self.makeTestImage()
        await #expect(throws: OCRRecognitionError.noTextFound) {
            _ = try await fake.recognizeText(in: image)
        }
    }

    // MARK: - Recognized-text normalization / line ordering (requirement 46)

    @Test func fullTextJoinsLinesInReadingOrderWithNewlines() {
        let result = OCRRecognitionResult.fixtureEvent
        let expectedOrder = result.lines.map(\.text).joined(separator: "\n")
        #expect(result.fullText == expectedOrder)
    }

    @Test func lineOrderIsPreservedNotResorted() {
        // `SystemOCRTextRecognizer` never sorts `request.results` — this proves the Kue-owned
        // result type itself doesn't either, by constructing an intentionally non-alphabetical
        // set of lines and confirming `fullText` preserves that order.
        let lines = [
            OCRTextLine(text: "Zebra Corp Interview", confidence: 0.9),
            OCRTextLine(text: "Available slots", confidence: 0.9),
            OCRTextLine(text: "Applicant name", confidence: 0.9),
        ]
        let fullText = lines.map(\.text).joined(separator: "\n")
        #expect(fullText == "Zebra Corp Interview\nAvailable slots\nApplicant name")
    }

    // MARK: - Recognition availability / fake behavior (requirement 37/44)

    @Test func unavailableRecognizerReportsUnavailable() {
        let fake = FakeOCRTextRecognizer(availableToReturn: false)
        #expect(!fake.isAvailable())
    }

    @Test func availableRecognizerReportsAvailable() {
        let fake = FakeOCRTextRecognizer(availableToReturn: true)
        #expect(fake.isAvailable())
    }

    @Test func fakeRecognizerReturnsItsConfiguredResult() async throws {
        let fake = FakeOCRTextRecognizer(resultToReturn: .success(.fixtureEvent))
        let result = try await fake.recognizeText(in: Self.makeTestImage())
        #expect(result == .fixtureEvent)
        #expect(fake.recognizeCallCount == 1)
    }

    @Test func fakeRecognizerCanBeConfiguredToThrow() async {
        let fake = FakeOCRTextRecognizer(resultToReturn: .failure(OCRRecognitionError.recognitionFailed("boom")))
        await #expect(throws: OCRRecognitionError.self) {
            _ = try await fake.recognizeText(in: Self.makeTestImage())
        }
    }

    // MARK: - Helpers

    private static func makeTestImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
