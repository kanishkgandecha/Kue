//
//  OCRImportView.swift
//  Kue
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input. Requirement 1/2/19/20: the "Image/Screenshot"
//  Add-flow entry point — pick one photo via the system `PhotosPicker`, recognize its text
//  on-device, and let the user review/edit that text before it ever reaches the parser. See
//  docs/19-screenshot-ocr-input.md for the full flow contract.
//
//  Never creates a `KueEvent` itself (requirement 31/32): `onContinue` hands the caller
//  (`HomeView`) an already-parsed `EventDraft`/`[DraftAmbiguity]` pair, built by running the
//  user-approved text through the *exact* `NLParsingPipeline` typed NL text already uses
//  (requirement 23/24) — the same "dismiss, then present the prefilled form" sequencing
//  `CalendarImportListView`/`HomeView.CalendarImportPhase` establishes, for the same reason.
//

import SwiftUI
import PhotosUI
import UIKit

struct OCRImportView: View {
    var onContinue: (EventDraft, [DraftAmbiguity]) -> Void

    @Environment(\.ocrTextRecognizer) private var ocrTextRecognizer
    @Environment(\.ocrUsesFixtureImageSource) private var usesFixtureImageSource
    @Environment(\.nlParser) private var nlParser
    @Environment(\.aiAvailabilityChecker) private var aiAvailabilityChecker
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case initial
        case loading
        case reviewing
        case noTextFound
        case error(String)
    }

    @State private var phase: Phase = .initial
    @State private var pickerItem: PhotosPickerItem?
    @State private var recognizedText = ""
    @State private var confidence: OCRConfidence = .high
    @State private var isParsing = false
    @State private var parseFailureMessage: String?
    @State private var isAIAvailable = true
    /// Requirement 40/41/42 — see `OCRRequestGeneration`'s own doc comment.
    @State private var generation = OCRRequestGeneration()
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .initial:
                    initialState
                case .loading:
                    loadingState
                case .reviewing:
                    reviewingState
                case .noTextFound:
                    messageState(
                        OCRRecognitionError.noTextFound.errorDescription ?? "",
                        systemImage: "text.viewfinder"
                    )
                case .error(let message):
                    messageState(message, systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("Scan Screenshot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelFlow() }
                }
            }
            .onAppear {
                isAIAvailable = aiAvailabilityChecker.currentAvailability().isAvailable
            }
            // Requirement 33/34 — cancels any in-flight image load/preprocess/recognize work
            // the moment this view leaves the hierarchy for *any* reason, so nothing keeps
            // running (and no large image buffer stays referenced) past that point. Never
            // calls `dismiss()` here: this view also "disappears" on the *successful* path,
            // when `HomeView.ocrFlowPhase` swaps this same sheet's content from `.scanning` to
            // `.editing(...)` — a `dismiss()` in that case would immediately re-close the sheet
            // `HomeView` had just switched to showing the prefilled `EventFormView` in
            // (confirmed empirically: this is exactly what `cancelFlow()` here used to do).
            // Explicit user cancellation is handled solely by the toolbar Cancel button.
            .onDisappear { processingTask?.cancel() }
            // Requirement 39 — accessible progress announcements: VoiceOver hears each phase
            // transition, not just whatever happens to be focused when it changes.
            .onChange(of: phase) { _, newPhase in
                AccessibilityNotification.Announcement(announcement(for: newPhase)).post()
            }
        }
    }

    // MARK: - Initial (picker) state

    @ViewBuilder
    private var initialState: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityHidden(true)

            // Requirement 21/22 — persistent, accurate, specific on-device disclosure, shown
            // before any image is even picked.
            Text("Processed on-device. The image you select is processed locally on this device and is never uploaded by Kue.")
                .font(KueTypography.footnote)
                .foregroundStyle(KueColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("ocrOnDeviceDisclosure")

            if usesFixtureImageSource {
                // Requirement 48 — UI tests never drive the real PhotosPicker or touch the
                // owner's Photos library; this deterministic stand-in feeds the exact same
                // `processSelectedImageData(_:)` path a real picker selection would.
                Button("Choose Test Image") {
                    startProcessing(data: OCRFixtureImage.data)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("ocrChooseFixtureImageButton")
            } else {
                // Requirement 2/3 — the system picker; PHPickerViewController-backed, so it
                // needs no Photo Library usage description and never requests broad library
                // access, only the one item the user explicitly picks.
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("ocrChoosePhotoButton")
                .onChange(of: pickerItem) { _, newItem in
                    guard let newItem else { return }
                    loadAndProcess(newItem)
                }
            }
        }
        .padding()
        // Deliberately no identifier on this outer container: SwiftUI can propagate a
        // container-level `.accessibilityIdentifier` down onto an interactive child that
        // already has its own — observed directly in a UI-test accessibility-tree dump, the
        // same issue `CalendarImportListView`'s own `requestAccessState` hit in Phase 4 — so
        // `ocrChooseFixtureImageButton`/`ocrChoosePhotoButton` alone are what a test should
        // match against; either one's presence already proves this state is showing.
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel("Processing image on-device")
            Text("Reading text on-device…")
                .font(.subheadline)
                .foregroundStyle(KueColor.secondaryText)
        }
        .padding()
        .accessibilityIdentifier("ocrLoadingState")
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reviewing state (requirement 19/20)

    private var reviewingState: some View {
        Form {
            Section {
                // Requirement 21 — the disclosure stays visible through the whole flow, not
                // just the initial screen.
                Text("Processed on-device. The image you select is processed locally on this device and is never uploaded by Kue.")
                    .font(KueTypography.footnote)
                    .foregroundStyle(KueColor.secondaryText)
                    .accessibilityIdentifier("ocrOnDeviceDisclosureReview")
            }

            if let warning = confidence.warningMessage {
                Section {
                    // Requirement 39 — non-color-only: an icon + specific text, not just a
                    // colored dot.
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(KueColor.warning)
                        .accessibilityIdentifier("ocrLowConfidenceWarning")
                }
            }

            Section("Recognized Text") {
                TextEditor(text: $recognizedText)
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("ocrRecognizedTextEditor")
                    .accessibilityLabel("Recognized text — edit before continuing")
            }

            if let parseFailureMessage {
                Section {
                    Text(parseFailureMessage)
                        .foregroundStyle(KueColor.error)
                        .accessibilityIdentifier("ocrParseFailureMessage")
                }
            }

            Section {
                Button("Try Another Photo") { resetToInitial() }
                    .accessibilityIdentifier("ocrTryAnotherPhotoButton")

                Button {
                    Task { await continueToParsingImpl() }
                } label: {
                    if isParsing {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .accessibilityIdentifier("ocrContinueButton")
                .disabled(isParsing || recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isAIAvailable)

                if !isAIAvailable {
                    // Requirement 37/38 — "parser unavailable" gets its own specific,
                    // actionable message (mirrors AIAvailabilityState's own copy), not a
                    // disabled button with no explanation.
                    Text(aiAvailabilityChecker.currentAvailability().message ?? "")
                        .font(KueTypography.footnote)
                        .foregroundStyle(KueColor.secondaryText)
                        .accessibilityIdentifier("ocrParserUnavailableMessage")
                }
            }
        }
        .accessibilityIdentifier("ocrReviewingState")
    }

    // MARK: - Error / no-text states

    private func messageState(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(message, systemImage: systemImage)
            Button("Choose Another Photo") { resetToInitial() }
                .accessibilityIdentifier("ocrChooseAnotherPhotoButton")
                .buttonStyle(.glassProminent)
        }
        // Deliberately no identifier on this outer container — see `initialState`'s own
        // comment; `ocrChooseAnotherPhotoButton`'s presence, or the message text itself,
        // already proves this state is showing.
    }

    private func announcement(for phase: Phase) -> String {
        switch phase {
        case .initial: return "Choose a photo to scan"
        case .loading: return "Reading text on-device"
        case .reviewing: return "Text recognized — review before continuing"
        case .noTextFound: return OCRRecognitionError.noTextFound.errorDescription ?? "No text found"
        case .error(let message): return message
        }
    }

    // MARK: - Image loading + processing (requirement 5/6/7/8/9/10/40/41/42)

    /// Requirement 5 — loads the picker item's data off the main thread (`loadTransferable`
    /// is itself async); requirement 6 — a nil/failed load is its own distinct, actionable
    /// state ("PhotosPicker loading failure"), not folded into a generic error.
    private func loadAndProcess(_ item: PhotosPickerItem) {
        processingTask?.cancel()
        let myGeneration = generation.advance()
        phase = .loading

        processingTask = Task {
            let loadedData: Data?
            do {
                loadedData = try await item.loadTransferable(type: Data.self)
            } catch {
                loadedData = nil
            }
            guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }
            guard let data = loadedData else {
                phase = .error("Couldn't load that photo. Try choosing another one.")
                return
            }
            await recognize(data: data, generation: myGeneration)
        }
    }

    /// The UI-test fixture path (requirement 48) — same downstream pipeline, no `PhotosPicker`
    /// / `PhotosPickerItem` involved at all.
    private func startProcessing(data: Data) {
        processingTask?.cancel()
        let myGeneration = generation.advance()
        phase = .loading
        processingTask = Task {
            await recognize(data: data, generation: myGeneration)
        }
    }

    private func recognize(data: Data, generation myGeneration: Int) async {
        // Requirement 6/7/8/9/10 — validated, downsampled, orientation-corrected before Vision
        // ever sees it; a pure, synchronous, fast check, but still routed through the same
        // cancellation/staleness guard as the async steps around it.
        let prepared: CGImage
        switch OCRImagePreprocessor.validateAndPrepare(data: data) {
        case .success(let image):
            prepared = image
        case .failure(let validationError):
            guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }
            phase = .error(validationError.errorDescription ?? "That image couldn't be used.")
            return
        }

        guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }

        guard ocrTextRecognizer.isAvailable() else {
            phase = .error(OCRRecognitionError.unavailable.errorDescription ?? "")
            return
        }

        do {
            let result = try await ocrTextRecognizer.recognizeText(in: prepared)
            guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }
            recognizedText = result.fullText
            confidence = result.confidence
            phase = .reviewing
        } catch let error as OCRRecognitionError {
            guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }
            if error == .noTextFound {
                phase = .noTextFound
            } else {
                phase = .error(error.errorDescription ?? "Couldn't read text from that image.")
            }
        } catch {
            guard !Task.isCancelled, generation.isCurrent(myGeneration) else { return }
            phase = .error("Couldn't read text from that image.")
        }
    }

    // MARK: - Continue to parsing (requirement 23/24/25)

    @available(iOS 26.0, *)
    private func continueToParsingImpl() async {
        isParsing = true
        parseFailureMessage = nil
        defer { isParsing = false }

        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Requirement 23/24 — the exact same pipeline typed NL text and the Share Extension
        // already route through; no OCR-specific parsing logic exists anywhere in this file.
        let outcome = await NLParsingPipeline.run(text: trimmed, parser: nlParser, timeZoneIdentifier: TimeZone.current.identifier)
        if let draft = outcome.draft {
            onContinue(draft, outcome.ambiguities)
        } else {
            parseFailureMessage = outcome.failureMessage
        }
    }

    // MARK: - Reset / cancel (requirement 32/33/34/35: nothing survives past this point)

    private func resetToInitial() {
        processingTask?.cancel()
        generation.advance()
        pickerItem = nil
        recognizedText = ""
        parseFailureMessage = nil
        confidence = .high
        phase = .initial
    }

    private func cancelFlow() {
        processingTask?.cancel()
        processingTask = nil
        generation.advance()
        recognizedText = ""
        parseFailureMessage = nil
        dismiss()
    }
}

/// Requirement 48 — a small, fixed, deterministically-generated JPEG (drawn at runtime via
/// Core Graphics, not a bundled asset) standing in for a real photo in UI tests. Never touches
/// disk or the Photos library.
enum OCRFixtureImage {
    static let data: Data = {
        let size = CGSize(width: 400, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black,
            ]
            "Fake OCR Fixture Image".draw(at: CGPoint(x: 16, y: 80), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }()
}

// Kue 2.0 Phase 7 — requirement 43: representative OCR states for the design review. Always
// the fake recognizer (never `SystemOCRTextRecognizer`) — Xcode's preview canvas must never
// touch the real Vision framework/Photos library (requirement 48's own spirit, applied here).
#Preview("OCR Import — Light") {
    OCRImportView { _, _ in }
        .environment(\.ocrTextRecognizer, FakeOCRTextRecognizer(resultToReturn: .success(.fixtureEvent)))
}

#Preview("OCR Import — Dark") {
    OCRImportView { _, _ in }
        .environment(\.ocrTextRecognizer, FakeOCRTextRecognizer(resultToReturn: .success(.fixtureEvent)))
        .preferredColorScheme(.dark)
}

#Preview("OCR Import — Large Dynamic Type") {
    OCRImportView { _, _ in }
        .environment(\.ocrTextRecognizer, FakeOCRTextRecognizer(resultToReturn: .success(.fixtureEvent)))
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
