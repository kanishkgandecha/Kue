//
//  AddHubView.swift
//  Kue
//
//  Kue 2.0 Phase 7 — the central Add destination (bottom navigation). Lists every event-
//  creation method as its own row; each one opens the *exact* existing flow those phases
//  already built (`EventFormView`, `CalendarImportListView`, `OCRImportView`,
//  `VoiceInputView`) — nothing here re-implements parsing, validation, Calendar/OCR/voice
//  logic, or persistence. This file only owns *which flow is currently presented*, moved
//  here verbatim from `HomeView`'s previous toolbar-menu version of the same state machine
//  (`CalendarImportPhase`/`OCRFlowPhase`/`VoiceFlowPhase`, the proven-safe single-
//  `.sheet(item:)`-per-flow shape documented on each enum below).
//
//  "Create Manually" and "Describe with Text" both open the same `EventFormView(.add(...))`
//  — that screen already *is* both capabilities in one place (its own `nlInputSection` up top,
//  manual fields below; see EventFormView.swift's header), so presenting two different screens
//  for what's actually one destination would be exactly the duplication the phase brief warns
//  against. The two rows exist because a user thinking "let me just type it out" and a user
//  thinking "let me fill in the fields" shouldn't have to guess which single "Add" button
//  covers both — they open the identical, already-built screen either way.
//

import SwiftUI
import SwiftData

struct AddHubView: View {
    @State private var isAddingEvent = false
    @State private var addEventType: EventType = .generic

    // Kue 2.0 Phase 4 — Import from Calendar. Single `.sheet(item:)` whose *content* switches
    // between the picker and the prefilled form — see `HomeView`'s original comment (preserved
    // here verbatim) for why this isn't two chained `.sheet(isPresented:)` modifiers: that
    // shape was observed to leave the second sheet presented but empty for this exact
    // picker → form transition.
    private enum CalendarImportPhase: Identifiable {
        case selecting
        case editing(EventDraft)
        var id: String {
            switch self {
            case .selecting: return "selecting"
            case .editing: return "editing"
            }
        }
    }
    @State private var calendarImportPhase: CalendarImportPhase?

    // Kue 2.0 Phase 5 — Screenshot/OCR import. Same one-continuous-sheet shape.
    private enum OCRFlowPhase: Identifiable {
        case scanning
        case editing(EventDraft, [DraftAmbiguity])
        var id: String {
            switch self {
            case .scanning: return "scanning"
            case .editing: return "editing"
            }
        }
    }
    @State private var ocrFlowPhase: OCRFlowPhase?

    // Kue 2.0 Phase 6 — Voice input. Same shape again.
    private enum VoiceFlowPhase: Identifiable {
        case recording
        case editing(EventDraft, [DraftAmbiguity])
        var id: String {
            switch self {
            case .recording: return "recording"
            case .editing: return "editing"
            }
        }
    }
    @State private var voiceFlowPhase: VoiceFlowPhase?
    /// Voice's own recovery states offer "Enter Manually"/"Scan a Screenshot Instead";
    /// consumed once `voiceFlowPhase`'s sheet has fully dismissed.
    @State private var pendingManualEntryAfterVoice = false
    @State private var pendingOCRAfterVoice = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    addRow(title: "Create Manually", subtitle: "Fill in the details yourself.", systemImage: "square.and.pencil", identifier: "addMethodManual") {
                        addEventType = .generic
                        isAddingEvent = true
                    }
                    addRow(title: "Describe with Text", subtitle: "Type a sentence — Kue fills in the details, on-device.", systemImage: "sparkles", identifier: "addMethodDescribe") {
                        addEventType = .generic
                        isAddingEvent = true
                    }
                } footer: {
                    Text("Both open the same form — Describe with Text just starts you in the Quick Add field.")
                }

                Section {
                    addRow(title: "Import from Calendar", subtitle: "Bring in an existing Apple Calendar event.", systemImage: "calendar.badge.plus", identifier: "importFromCalendarButton") {
                        calendarImportPhase = .selecting
                    }
                    addRow(title: "Scan Screenshot", subtitle: "Recognize event details from an image, on-device.", systemImage: "text.viewfinder", identifier: "scanScreenshotButton") {
                        ocrFlowPhase = .scanning
                    }
                    addRow(title: "Voice Input", subtitle: "Speak the details — recognized on-device.", systemImage: "mic.fill", identifier: "voiceInputButton") {
                        voiceFlowPhase = .recording
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isAddingEvent) {
            EventFormView(mode: .add(initialEventType: addEventType))
        }
        .sheet(item: $calendarImportPhase) { phase in
            switch phase {
            case .selecting:
                CalendarImportListView { draft in
                    calendarImportPhase = .editing(draft)
                }
            case .editing(let draft):
                EventFormView(prefilledDraft: draft, ambiguities: [], source: .calendarImport)
            }
        }
        .sheet(item: $ocrFlowPhase) { phase in
            switch phase {
            case .scanning:
                OCRImportView { draft, ambiguities in
                    ocrFlowPhase = .editing(draft, ambiguities)
                }
            case .editing(let draft, let ambiguities):
                EventFormView(prefilledDraft: draft, ambiguities: ambiguities, source: .ocr)
            }
        }
        .sheet(item: $voiceFlowPhase, onDismiss: presentPendingFlowAfterVoiceDismissal) { phase in
            switch phase {
            case .recording:
                VoiceInputView(
                    onContinue: { draft, ambiguities in
                        voiceFlowPhase = .editing(draft, ambiguities)
                    },
                    onSwitchToManualEntry: {
                        pendingManualEntryAfterVoice = true
                        voiceFlowPhase = nil
                    },
                    onSwitchToOCR: {
                        pendingOCRAfterVoice = true
                        voiceFlowPhase = nil
                    }
                )
            case .editing(let draft, let ambiguities):
                EventFormView(prefilledDraft: draft, ambiguities: ambiguities, source: .voice)
            }
        }
    }

    private func addRow(title: String, subtitle: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: KueSpacing.xxs) {
                    Text(title)
                        .font(KueTypography.cardTitle)
                        .foregroundStyle(KueColor.primaryText)
                    Text(subtitle)
                        .font(KueTypography.cardSubtitle)
                        .foregroundStyle(KueColor.secondaryText)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(KueColor.accent)
                    .font(.system(size: KueIconSize.medium))
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func presentPendingFlowAfterVoiceDismissal() {
        if pendingManualEntryAfterVoice {
            pendingManualEntryAfterVoice = false
            addEventType = .generic
            isAddingEvent = true
        } else if pendingOCRAfterVoice {
            pendingOCRAfterVoice = false
            ocrFlowPhase = .scanning
        }
    }
}

#Preview("Add Hub — Light") {
    AddHubView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}

#Preview("Add Hub — Dark") {
    AddHubView()
        .modelContainer(ModelContainerFactory.makeInMemory())
        .preferredColorScheme(.dark)
}
