//
//  OCREnvironment.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. Dependency injection for `OCRTextRecognizing` —
//  views read `\.ocrTextRecognizer` from the SwiftUI environment rather than constructing a
//  `SystemOCRTextRecognizer` themselves, mirroring `CalendarEnvironment.swift`'s
//  `\.calendarProvider` seam exactly. `KueApp` installs the real implementation at the root
//  (or, when launched with `FakeOCRTextRecognizer.uiTestLaunchArgument`, a deterministic fake).
//

import SwiftUI

private struct OCRTextRecognizerKey: EnvironmentKey {
    /// No-op default (always unavailable, never touches Vision) so a context that never sets
    /// this — a preview, an unrelated test — still compiles and reports "unavailable" rather
    /// than crashing.
    static let defaultValue: OCRTextRecognizing = UnavailableOCRTextRecognizer()
}

/// Requirement 48 — the UI-test image-source seam: when `true`, `OCRImportView` shows a
/// deterministic "choose a fixture image" control instead of the real `PhotosPicker`, so a UI
/// test never has to (and never can) drive the system Photos picker or touch the owner's real
/// Photos library.
private struct OCRUsesFixtureImageSourceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ocrTextRecognizer: OCRTextRecognizing {
        get { self[OCRTextRecognizerKey.self] }
        set { self[OCRTextRecognizerKey.self] = newValue }
    }

    var ocrUsesFixtureImageSource: Bool {
        get { self[OCRUsesFixtureImageSourceKey.self] }
        set { self[OCRUsesFixtureImageSourceKey.self] = newValue }
    }
}

@MainActor
private struct UnavailableOCRTextRecognizer: OCRTextRecognizing {
    func isAvailable() -> Bool { false }
    func recognizeText(in image: CGImage) async throws -> OCRRecognitionResult {
        throw OCRRecognitionError.unavailable
    }
}
