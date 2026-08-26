//
//  EventFormView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Add" / "Widget configuration" and docs/04-event-types.md
//  "Per-type fields". One form for both create and edit — manual entry *is* the confirmation
//  (docs/09-screens-and-ux.md "Manual entry skips this screen entirely"), so there's no
//  separate AI-draft review step here.
//

import SwiftUI
import SwiftData

struct EventFormView: View {
    enum Mode {
        case add
        case edit(KueEvent)
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allEvents: [KueEvent]

    @State private var draft: EventDraft
    @State private var errors: [EventValidationError] = []
    @State private var duplicate: KueEvent?
    @State private var didAcknowledgeDuplicate = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add:
            _draft = State(initialValue: EventDraft())
        case .edit(let event):
            _draft = State(initialValue: EventDraft(
                title: event.title,
                eventType: event.eventType,
                startDate: event.startDate,
                isAllDay: event.isAllDay,
                endDate: event.endDate ?? event.startDate.addingTimeInterval(86_400),
                location: event.location ?? "",
                notes: event.notes ?? "",
                priority: event.priority,
                timeZoneIdentifier: event.timeZoneIdentifier
            ))
        }
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if let duplicate {
                    Section {
                        Label("You already have \"\(duplicate.title)\" on this date.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("duplicateWarning")
                    }
                }

                Section("Event") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("eventTitleField")

                    Picker("Type", selection: $draft.eventType) {
                        ForEach(EventType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .accessibilityIdentifier("eventTypePicker")

                    Picker("Priority", selection: $draft.priority) {
                        Text("Low").tag(Priority.low)
                        Text("Medium").tag(Priority.medium)
                        Text("High").tag(Priority.high)
                    }
                }

                Section("When") {
                    Toggle("All Day", isOn: $draft.isAllDay)
                        .accessibilityIdentifier("allDayToggle")

                    DatePicker(
                        draft.eventType == .trip ? "Starts" : "Date",
                        selection: $draft.startDate,
                        displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("startDatePicker")

                    if draft.eventType == .trip {
                        DatePicker(
                            "Returns",
                            selection: $draft.endDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .accessibilityIdentifier("endDatePicker")
                    }

                    if isEditing {
                        Picker("Timezone", selection: $draft.timeZoneIdentifier) {
                            ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { identifier in
                                Text(identifier).tag(identifier)
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField("Location (optional)", text: $draft.location)
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors) { error in
                            Label(error.errorDescription ?? "", systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("validationErrors")
                }
            }
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save() }
                        .accessibilityIdentifier("saveEventButton")
                }
            }
            .onChange(of: draft.title) { checkDuplicate() }
            .onChange(of: draft.startDate) { checkDuplicate() }
            .onAppear { checkDuplicate() }
        }
    }

    private func checkDuplicate() {
        let excludedID: UUID? = {
            if case .edit(let event) = mode { return event.id }
            return nil
        }()
        duplicate = DuplicateDetectionService.findDuplicate(
            title: draft.title,
            startDate: draft.startDate,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            excluding: excludedID,
            in: allEvents
        )
    }

    private func save() {
        errors = EventValidator.validate(draft)
        guard errors.isEmpty else { return }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        switch mode {
        case .add:
            let event = KueEvent(
                title: title,
                eventType: draft.eventType,
                startDate: draft.startDate,
                endDate: draft.eventType == .trip ? draft.endDate : nil,
                estimatedDurationMinutes: draft.eventType.defaultEstimatedDurationMinutes,
                isAllDay: draft.isAllDay,
                location: draft.location.isEmpty ? nil : draft.location,
                notes: draft.notes.isEmpty ? nil : draft.notes,
                source: .manual,
                priority: draft.priority
            )
            EventStatusEngine.reconcile(event, now: now)
            modelContext.insert(event)
            let widgetConfiguration = WidgetConfiguration(
                event: event,
                widgetType: defaultWidgetType(for: draft.eventType)
            )
            modelContext.insert(widgetConfiguration)
            event.widgetConfiguration = widgetConfiguration
            SchedulingEngine.regenerateTasks(for: event, context: modelContext, now: now)
        case .edit(let event):
            event.title = title
            event.eventType = draft.eventType
            event.startDate = draft.startDate
            event.endDate = draft.eventType == .trip ? draft.endDate : nil
            event.isAllDay = draft.isAllDay
            event.location = draft.location.isEmpty ? nil : draft.location
            event.notes = draft.notes.isEmpty ? nil : draft.notes
            event.priority = draft.priority
            event.timeZoneIdentifier = draft.timeZoneIdentifier
            event.updatedAt = now
            EventStatusEngine.reconcile(event, now: now)
            // Regenerates from event.schedule.rules per docs/05-scheduling-engine.md
            // "Editing an event after its schedule is generated" — safe to call
            // unconditionally since it's a no-op for anything a completed task already covers.
            SchedulingEngine.regenerateTasks(for: event, context: modelContext, now: now)
        }

        try? modelContext.save()
        dismiss()
    }

    /// docs/07-widget-engine.md "Widget types (V1)" default-per-event-type mapping.
    private func defaultWidgetType(for eventType: EventType) -> WidgetType {
        switch eventType {
        case .interview, .exam, .deadline: return .preparation
        case .trip: return .timeline
        case .generic: return .countdown
        }
    }
}

#Preview {
    EventFormView(mode: .add)
        .modelContainer(ModelContainerFactory.makeInMemory())
}
