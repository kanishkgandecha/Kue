//
//  MacEventEditorView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — native Mac event editor. Uses the exact same `EventDraft`/
//  `EventValidator`/`EventSaveService` (Shared/) the iPhone `EventFormView` now also calls
//  (see that file's own Kue 3.0 Phase 1 note) — one validated draft shape, one save path, on
//  both platforms. Never reintroduces the detached-fault crash Kue 2.0 fixed: this view reads
//  `mode`'s `KueEvent` only to seed the initial draft and, on save, hands the *fresh* saved
//  event's id back to the caller — it never carries a view-owned model/context across an
//  asynchronous boundary itself (the reconciliation `Task` below captures only the id and the
//  container, mirroring `EventFormView.save()`'s own pattern exactly).
//

import SwiftUI
import SwiftData

enum MacEventEditorMode {
    case add(initialEventType: EventType)
    /// Kue 3.0 Phase 1 cleanup — Calendar import's "draft review" step: a fully-built
    /// `EventDraft` (from `CalendarImportPipeline.draft`), still freely editable here before
    /// saving, exactly like `EventFormView(prefilledDraft:...)` on iOS.
    case addFromDraft(EventDraft, source: EventSource)
    case edit(KueEvent)
}

struct MacEventEditorView: View {
    let mode: MacEventEditorMode
    var onSaved: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft = EventDraft()
    @State private var editScope: RecurrenceEditScope = .thisOccurrence
    @State private var errors: [EventValidationError] = []
    @State private var recurrenceErrors: [RecurrenceValidationError] = []

    private var isEditingSeriesOccurrence: Bool {
        if case .edit(let event) = mode { return event.seriesID != nil }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if !errors.isEmpty || !recurrenceErrors.isEmpty {
                    Section {
                        ForEach(errors) { Text($0.errorDescription ?? "").foregroundStyle(.red) }
                        ForEach(recurrenceErrors, id: \.self) { Text($0.errorDescription ?? "").foregroundStyle(.red) }
                    }
                }

                Section("Event") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("eventTitleField")
                    Picker("Type", selection: $draft.eventType) {
                        ForEach(EventType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("All Day", isOn: $draft.isAllDay)
                    DatePicker("Starts", selection: $draft.startDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    if draft.eventType == .trip {
                        DatePicker("Returns", selection: $draft.endDate, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }

                Section("Details") {
                    TextField("Location", text: $draft.location)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if isEditingSeriesOccurrence {
                    Section("Applies To") {
                        Picker("Scope", selection: $editScope) {
                            Text("This Event").tag(RecurrenceEditScope.thisOccurrence)
                            Text("This and Future Events").tag(RecurrenceEditScope.thisAndFuture)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                if isRecurrenceEditable {
                    recurrenceSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelEventEditorButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityIdentifier("saveEventButton")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear(perform: seedDraft)
    }

    // MARK: - Recurrence

    /// Kue 2.0 Phase 3's own rule: recurrence controls are editable when adding, or when
    /// editing a *non*-series event (which can start a fresh series) — an existing series
    /// occurrence's own recurrence is changed only through "This and Future," not this toggle.
    private var isRecurrenceEditable: Bool {
        !isEditingSeriesOccurrence
    }

    private var recurrenceSection: some View {
        Section("Repeat") {
            Toggle("Repeats", isOn: $draft.isRecurring)
            if draft.isRecurring {
                Picker("Frequency", selection: $draft.recurrenceFrequency) {
                    ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Stepper("Every \(draft.recurrenceInterval) \(draft.recurrenceFrequency.rawValue)(s)", value: $draft.recurrenceInterval, in: 1...30)
                Picker("Ends", selection: $draft.recurrenceEndKind) {
                    ForEach(RecurrenceEndKind.allCases) { Text($0.displayName).tag($0) }
                }
                switch draft.recurrenceEndKind {
                case .never: EmptyView()
                case .onDate: DatePicker("End Date", selection: $draft.recurrenceEndDate, displayedComponents: [.date])
                case .afterCount: Stepper("After \(draft.recurrenceOccurrenceCount) occurrences", value: $draft.recurrenceOccurrenceCount, in: 1...365)
                }
                if let rule = draft.recurrenceRule {
                    Text(rule.summary(startDate: draft.startDate))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Seed / Save

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func seedDraft() {
        switch mode {
        case .add(let initialEventType):
            draft = EventDraft()
            draft.eventType = initialEventType
        case .addFromDraft(let prefilled, _):
            draft = prefilled
        case .edit(let event):
            draft.title = event.title
            draft.eventType = event.eventType
            draft.startDate = event.startDate
            draft.isAllDay = event.isAllDay
            draft.endDate = event.endDate ?? event.startDate.addingTimeInterval(86_400)
            draft.location = event.location ?? ""
            draft.notes = event.notes ?? ""
            draft.priority = event.priority
            draft.timeZoneIdentifier = event.timeZoneIdentifier
            draft.applyRecurrenceRule(event.recurrence)
        }
    }

    private func save() {
        errors = EventValidator.validate(draft)
        recurrenceErrors = isRecurrenceEditable ? EventValidator.validateRecurrence(draft) : []
        guard errors.isEmpty, recurrenceErrors.isEmpty else { return }

        let now = Date()
        let saveMode: EventSaveMode
        switch mode {
        case .add:
            saveMode = .add(source: .manual)
        case .addFromDraft(_, let source):
            saveMode = .add(source: source)
        case .edit(let event):
            saveMode = .edit(event: event, editScope: editScope)
        }
        let result = EventSaveService.save(draft: draft, mode: saveMode, context: modelContext, now: now)

        let eventID = result.event.id
        let container = modelContext.container
        Task {
            await EventCreationService.reconcileAfterWrite(eventID: eventID, container: container, now: now)
        }
        onSaved(eventID)
        dismiss()
    }
}
