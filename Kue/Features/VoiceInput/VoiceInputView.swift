//
//  VoiceInputView.swift
//  Kue
//
//  Kue 2.0 Phase 6 — On-Device Voice Input. Requirement 1/23/35/36: the "Voice" Add-flow entry
//  point — record, watch a live partial transcript, stop and review/edit the final transcript,
//  then continue to parsing. See docs/20-voice-input.md for the full flow contract.
//
//  Never creates a `KueEvent` itself (requirement 49/50): `onContinue` hands the caller
//  (`HomeView`) an already-parsed `EventDraft`/`[DraftAmbiguity]` pair, built by running the
//  user-approved transcript through the *exact* `NLParsingPipeline` typed NL text already uses
//  (requirement 42/43) — the same one-continuous-`.sheet(item:)` sequencing
//  `CalendarImportPhase`/`OCRFlowPhase` establish.
//

import SwiftUI

struct VoiceInputView: View {
    var onContinue: (EventDraft, [DraftAmbiguity]) -> Void
    var onSwitchToManualEntry: () -> Void
    var onSwitchToOCR: () -> Void

    @Environment(\.voiceAuthorizationChecker) private var authorizationChecker
    @Environment(\.voiceAudioSessionManager) private var audioSessionManager
    @Environment(\.voiceMicrophoneCapture) private var microphoneCapture
    @Environment(\.voiceSpeechRecognizer) private var speechRecognizer
    @Environment(\.nlParser) private var nlParser
    @Environment(\.aiAvailabilityChecker) private var aiAvailabilityChecker
    @Environment(\.dismiss) private var dismiss
    // `openURL`, not `UIApplication.shared.open(_:)` — this file is also synchronized into the
    // KueShare extension target (see AGENTS.md "Three targets"), where `UIApplication.shared`
    // doesn't compile at all; `openURL` is the extension-safe SwiftUI equivalent.
    @Environment(\.openURL) private var openURL

    @State private var coordinator: VoiceInputCoordinator?
    @State private var isParsing = false
    @State private var parseFailureMessage: String?
    @State private var isAIAvailable = true
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    content(coordinator)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Voice Input")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelFlow() }
                }
            }
            .onAppear {
                let newCoordinator = VoiceInputCoordinator(
                    authorizationChecker: authorizationChecker,
                    audioSessionManager: audioSessionManager,
                    microphoneCapture: microphoneCapture,
                    speechRecognizer: speechRecognizer
                )
                newCoordinator.refreshAvailability()
                coordinator = newCoordinator
                isAIAvailable = aiAvailabilityChecker.currentAvailability().isAvailable
                startTicking()
            }
            .onDisappear {
                tickTask?.cancel()
                coordinator?.cancel()
            }
        }
    }

    // MARK: - Ticking (requirement 25/26/27/28) — drives `coordinator.tick()` in real time;
    // the coordinator's own logic is a pure function of the `now` it's given, so this is the
    // only place real wall-clock time is involved.

    private func startTicking() {
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                coordinator?.tick()
            }
        }
    }

    // MARK: - Content per phase

    @ViewBuilder
    private func content(_ coordinator: VoiceInputCoordinator) -> some View {
        switch coordinator.phase {
        case .idle:
            initialState(coordinator)
        case .recording:
            recordingState(coordinator)
        case .finalizing:
            ProgressView("Finishing up…")
                .accessibilityIdentifier("voiceFinalizingState")
        case .reviewing:
            reviewingState(coordinator)
        case .noSpeechDetected:
            recoveryState(
                coordinator,
                message: VoiceRecognitionError.noSpeechDetected.errorDescription ?? "",
                systemImage: "waveform.slash"
            )
        case .error(let message):
            recoveryState(coordinator, message: message, systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: - Initial state (requirement 11/12/37)

    @ViewBuilder
    private func initialState(_ coordinator: VoiceInputCoordinator) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // Requirement 37 — persistent, accurate, specific on-device disclosure, shown
            // before any permission is even requested.
            Text("Kue processes your voice on-device to turn it into event details. Kue requests on-device speech recognition and never uploads or keeps your recording. Voice input is optional.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("voiceOnDeviceDisclosure")

            Button {
                Task { await coordinator.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("voiceStartRecordingButton")
        }
        .padding()
    }

    // MARK: - Recording state (requirement 24/25/31/56)

    @ViewBuilder
    private func recordingState(_ coordinator: VoiceInputCoordinator) -> some View {
        VStack(spacing: 20) {
            // Requirement 24/56 — unmistakable, non-color-only: an icon plus the word
            // "Recording," not a color alone.
            Label("Recording", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
                .accessibilityIdentifier("voiceRecordingIndicator")
                .accessibilityLabel("Recording in progress")

            Text(Self.formattedDuration(coordinator.elapsedSeconds))
                .font(.system(.title2, design: .monospaced))
                .accessibilityIdentifier("voiceDurationLabel")
                .accessibilityLabel("Elapsed time")
                .accessibilityValue(Self.formattedDuration(coordinator.elapsedSeconds))

            ScrollView {
                Text(coordinator.transcript.isEmpty ? "Listening…" : coordinator.transcript)
                    .foregroundStyle(coordinator.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 160)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("voiceLiveTranscript")
            .accessibilityLabel("Live transcript")
            .accessibilityValue(coordinator.transcript.isEmpty ? "Listening" : coordinator.transcript)

            Button("Stop") { coordinator.stopRecording() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("voiceStopButton")
        }
        .padding()
    }

    // MARK: - Reviewing state (requirement 35/36)

    private func reviewingState(_ coordinator: VoiceInputCoordinator) -> some View {
        Form {
            Section {
                Text("Kue processes your voice on-device to turn it into event details. Kue requests on-device speech recognition and never uploads or keeps your recording. Voice input is optional.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voiceOnDeviceDisclosureReview")
            }

            if let autoStopReason = coordinator.autoStopReason {
                Section {
                    Text(autoStopReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceAutoStopReason")
                }
            }

            if let warning = coordinator.confidence.warningMessage {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voiceLowConfidenceWarning")
                }
            }

            Section("Transcript") {
                TextEditor(text: Binding(
                    get: { coordinator.transcript },
                    set: { newValue in
                        coordinator.hasUserEdited = true
                        coordinator.setTranscript(newValue)
                    }
                ))
                .frame(minHeight: 160)
                .accessibilityIdentifier("voiceTranscriptEditor")
                .accessibilityLabel("Transcript — edit before continuing")
            }

            if let parseFailureMessage {
                Section {
                    Text(parseFailureMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("voiceParseFailureMessage")
                }
            }

            Section {
                Button("Record Again") { Task { await coordinator.startRecording() } }
                    .accessibilityIdentifier("voiceRecordAgainButton")

                Button {
                    Task { await continueToParsingImpl(coordinator) }
                } label: {
                    if isParsing {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .accessibilityIdentifier("voiceContinueButton")
                .disabled(isParsing || coordinator.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isAIAvailable)

                if !isAIAvailable {
                    Text(aiAvailabilityChecker.currentAvailability().message ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceParserUnavailableMessage")
                }
            }
        }
        .accessibilityIdentifier("voiceReviewingState")
    }

    // MARK: - Recovery states (requirement 9/16/51/52)

    @ViewBuilder
    private func recoveryState(_ coordinator: VoiceInputCoordinator, message: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(message, systemImage: systemImage)

            if coordinator.authorization.microphone.canOpenSettingsToChange || coordinator.authorization.speech.canOpenSettingsToChange {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .accessibilityIdentifier("voiceOpenSettingsButton")
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try Again") { coordinator.retry() }
                    .accessibilityIdentifier("voiceRetryButton")
                    .buttonStyle(.borderedProminent)
            }

            Button("Enter Manually") { onSwitchToManualEntry() }
                .accessibilityIdentifier("voiceSwitchToManualButton")

            Button("Scan a Screenshot Instead") { onSwitchToOCR() }
                .accessibilityIdentifier("voiceSwitchToOCRButton")
        }
        // Deliberately no identifier on this outer container — a container-level
        // `.accessibilityIdentifier` was observed (in a UI-test accessibility-tree dump) to
        // override every interactive child's own identifier underneath it, the same issue
        // `OCRImportView`'s `messageState`/`CalendarImportListView`'s `requestAccessState` hit
        // in Phases 4/5. Each button's own identifier, or the message text itself, already
        // proves this state is showing.
    }

    // MARK: - Continue to parsing (requirement 42/43/44)

    @available(iOS 26.0, *)
    private func continueToParsingImpl(_ coordinator: VoiceInputCoordinator) async {
        isParsing = true
        parseFailureMessage = nil
        defer { isParsing = false }

        let trimmed = coordinator.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Requirement 42/43 — the exact same pipeline typed NL text, Calendar-imported text,
        // and OCR-recognized text all route through; no voice-specific parsing logic exists
        // anywhere in this file.
        let outcome = await NLParsingPipeline.run(text: trimmed, parser: nlParser, timeZoneIdentifier: TimeZone.current.identifier)
        if let draft = outcome.draft {
            onContinue(draft, outcome.ambiguities)
        } else {
            parseFailureMessage = outcome.failureMessage
        }
    }

    // MARK: - Cancel (requirement 50/53)

    private func cancelFlow() {
        tickTask?.cancel()
        coordinator?.cancel()
        dismiss()
    }

    private static func formattedDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
