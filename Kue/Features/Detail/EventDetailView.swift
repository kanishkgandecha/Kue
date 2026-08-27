//
//  EventDetailView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Screen inventory" — Event detail: Event, Timeline, Tasks,
//  Widget, Notifications. Info is fully functional this phase; Timeline/Tasks/Notifications
//  show restrained empty states since scheduling/notifications aren't built yet (Widget is
//  functional as *settings*, per docs/09-screens-and-ux.md "Widget configuration" — no
//  widget rendering here, just editing the WidgetConfiguration model).
//

import SwiftUI
import SwiftData

private enum DetailTab: String, CaseIterable {
    case info = "Info"
    case timeline = "Timeline"
    case tasks = "Tasks"
    case widget = "Widget"
    case notifications = "Notifications"
}

struct EventDetailView: View {
    @Bindable var event: KueEvent

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var tab: DetailTab = .info
    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var isCustomizingSchedule = false
    @State private var isDuplicating = false
    @State private var duplicationPresentation: DuplicationPresentation?

    /// Kue 2.0 Phase 2, requirement 9 — wraps what `EventDuplicationService.duplicate`
    /// returned so the sheet below can show the same duplicate-warning banner
    /// `EventFormView` shows, without threading extra optionals through `EventDetailView`
    /// itself (keeps this view thin — requirement 11).
    private struct DuplicationPresentation: Identifiable {
        let id = UUID()
        let newEvent: KueEvent
        let detectedDuplicate: KueEvent?
    }

    /// Reconciliation rule 1 (docs/04-event-types.md): always recompute status on a
    /// single-event read rather than trusting the persisted value — except archive, which is
    /// a terminal override nothing here should silently revert.
    private var displayedStatus: EventStatus {
        event.status == .archived ? .archived : EventStatusEngine.derive(for: event)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch tab {
            case .info: infoTab
            case .timeline: timelineTab
            case .tasks: tasksTab
            case .widget: widgetTab
            case .notifications: notificationsTab
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { isEditing = true }
                    .accessibilityIdentifier("editEventButton")
                    .disabled(displayedStatus == .archived)
            }
        }
        .sheet(isPresented: $isEditing) {
            EventFormView(mode: .edit(event))
        }
        .sheet(item: $duplicationPresentation) { presentation in
            NavigationStack {
                VStack(spacing: 0) {
                    if let duplicate = presentation.detectedDuplicate {
                        Label("You already have \"\(duplicate.title)\" on this date.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding()
                            .accessibilityIdentifier("duplicateWarning")
                    }
                    EventDetailView(event: presentation.newEvent)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { duplicationPresentation = nil }
                    }
                }
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            if event.seriesID != nil {
                // Kue 2.0 Phase 3 — destructive series actions must clearly state their scope
                // (requirement 16): each option names exactly what it deletes.
                Button("Delete This Occurrence", role: .destructive) {
                    OccurrenceReconciliationService.deleteOccurrence(event, scope: .thisOccurrence, context: modelContext)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteOccurrenceButton")
                Button("Delete This and Future Occurrences", role: .destructive) {
                    OccurrenceReconciliationService.deleteOccurrence(event, scope: .thisAndFuture, context: modelContext)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteThisAndFutureButton")
            } else {
                Button("Delete", role: .destructive) {
                    EventActions.delete(event, context: modelContext)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteButton")
            }
        }
        .task {
            // Idempotent — lazily seeds/refreshes a schedule for events that predate this
            // view being open (or Phase 3 itself), without duplicating anything already there.
            SchedulingEngine.regenerateTasks(for: event, context: modelContext)
            // Passive trigger, same as foreground/background replenishment — never prompts
            // for permission (docs/08-notifications.md "Permission handling").
            let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
            await NotificationEngine.reschedule(context: modelContext, intensity: intensity, scheduler: SystemNotificationScheduler.shared)
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        Form {
            Section {
                LabeledContent("Type", value: event.eventType.displayName)
                LabeledContent("Status", value: statusLabel)
                LabeledContent("Starts", value: event.startDate.formatted(dateStyle))
                if event.eventType == .trip, let endDate = event.endDate {
                    LabeledContent("Returns", value: endDate.formatted(dateStyle))
                }
                LabeledContent("All Day", value: event.isAllDay ? "Yes" : "No")
                if let location = event.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                LabeledContent("Priority", value: event.priority.rawValue.capitalized)
                LabeledContent("Timezone", value: event.timeZoneIdentifier)
                // Kue 2.0 Phase 3 — a plain, read-only summary of the series this occurrence
                // belongs to (docs/17-recurring-events.md "UI").
                if let rule = event.recurrence {
                    LabeledContent("Repeats", value: rule.summary(startDate: event.recurrenceAnchorDate ?? event.startDate))
                }
            }

            if let notes = event.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section("Actions") {
                if displayedStatus == .archived {
                    Button("Unarchive") {
                        Task { await EventActions.unarchive(event, context: modelContext) }
                    }
                    .accessibilityIdentifier("unarchiveEventButton")
                } else {
                    if event.isCancelled {
                        Button("Un-cancel") {
                            Task { await EventActions.uncancel(event, context: modelContext) }
                        }
                    } else {
                        Button("Cancel Event", role: .destructive) {
                            EventActions.cancel(event, context: modelContext)
                        }
                        .accessibilityIdentifier("cancelEventButton")
                    }

                    if event.isManuallyCompleted {
                        Button("Mark Not Complete") {
                            Task { await EventActions.uncomplete(event, context: modelContext) }
                        }
                    } else {
                        Button("Mark Complete") {
                            EventActions.complete(event, context: modelContext)
                        }
                        .accessibilityIdentifier("completeEventButton")
                    }

                    // Kue 2.0 Phase 3 — skip is a recurrence-only action: only meaningful for
                    // a materialized occurrence (docs/17-recurring-events.md "Occurrence
                    // actions"); a non-recurring event has no "the series continues" to skip
                    // to.
                    if event.seriesID != nil {
                        if event.isSkipped {
                            Button("Un-skip") {
                                Task { await EventActions.unskip(event, context: modelContext) }
                            }
                            .accessibilityIdentifier("unskipOccurrenceButton")
                        } else {
                            Button("Skip This Occurrence") {
                                EventActions.skip(event, context: modelContext)
                            }
                            .accessibilityIdentifier("skipOccurrenceButton")
                        }
                    }

                    Button("Archive") {
                        EventActions.archive(event, context: modelContext)
                    }
                    .accessibilityIdentifier("archiveEventButton")
                }

                Button {
                    duplicateEvent()
                } label: {
                    if isDuplicating {
                        ProgressView()
                    } else {
                        Text("Duplicate Event")
                    }
                }
                .accessibilityIdentifier("duplicateEventButton")
                .disabled(isDuplicating)

                Button("Delete Event", role: .destructive) {
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier("deleteEventButton")
            }
        }
    }

    private var statusLabel: String {
        switch displayedStatus {
        case .draft: return "Draft"
        case .upcoming: return "Upcoming"
        case .preparing: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .active: return "Active"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .archived: return "Archived"
        }
    }

    private var dateStyle: Date.FormatStyle {
        event.isAllDay ? .dateTime.month().day().year() : .dateTime.month().day().year().hour().minute()
    }

    /// Kue 2.0 Phase 3, requirement 16 — states scope up front, before the dialog's own
    /// per-button scope labels, for a series occurrence.
    private var deleteConfirmationTitle: String {
        guard event.seriesID != nil else {
            return "Delete \"\(event.title)\"? This removes its tasks, schedule, and widget settings too."
        }
        return "Delete \"\(event.title)\"? Choose whether this removes just this occurrence or this and every future occurrence in the series."
    }

    // MARK: - Timeline / Tasks (Phase 3) / Notifications (still a later phase)

    private var sortedTasks: [KueTask] {
        event.tasks.sorted { $0.dueDate < $1.dueDate }
    }

    /// Chronological view of the same generated tasks — due date first, no completion
    /// affordance (that's Tasks). Distinguishes "when does prep happen" from "what's left."
    private var timelineTab: some View {
        VStack(spacing: 0) {
            if sortedTasks.isEmpty {
                ContentUnavailableView(
                    "No Preparation Timeline",
                    systemImage: "calendar.badge.clock",
                    description: Text(timelineEmptyReason)
                )
            } else {
                List(sortedTasks) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.dueDate.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(task.title)
                        Text(task.offsetLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // docs/09-screens-and-ux.md "Custom schedule editing" — reached from here, not
            // the Tasks tab, since this screen edits the *rule set* the tasks come from.
            Button("Customize Schedule") {
                isCustomizingSchedule = true
            }
            .accessibilityIdentifier("customizeScheduleButton")
            .padding()
            .disabled(displayedStatus == .archived)
        }
        .sheet(isPresented: $isCustomizingSchedule) {
            EditScheduleView(event: event)
        }
    }

    /// docs/05-scheduling-engine.md "Backward-scheduling clamp" — an event starting within
    /// `SchedulingEngine.minimumLeadTime` legitimately has zero surviving offsets; say so
    /// rather than implying something's broken.
    private var timelineEmptyReason: String {
        event.startDate.timeIntervalSinceNow < SchedulingEngine.minimumLeadTime
            ? "This event is starting too soon for any preparation task to fit."
            : "No schedule has been generated for this event yet."
    }

    private var tasksTab: some View {
        Group {
            if sortedTasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks Yet",
                    systemImage: "checklist",
                    description: Text(timelineEmptyReason)
                )
            } else {
                List(sortedTasks) { task in
                    HStack {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(task.title)
                            Text(task.offsetLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// docs/09-screens-and-ux.md "Event detail" lists Notifications as one of its tabs — this
    /// was a placeholder ("Reminders arrive in Phase 8") that outlived Phase 8 shipping;
    /// fixed during the Phase 10 audit. Reuses `NotificationCandidateBuilder` (Shared/)
    /// directly — the exact same candidate list `NotificationEngine.reschedule` would
    /// actually schedule, not a re-derived summary.
    private var notificationsTab: some View {
        let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
        let candidates = NotificationCandidateBuilder.prioritized(
            NotificationCandidateBuilder.filter(NotificationCandidateBuilder.candidates(for: event), intensity: intensity)
        )
        return Group {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Upcoming Notifications",
                    systemImage: "bell.slash",
                    description: Text("Nothing left to remind you about for this event.")
                )
            } else {
                List(candidates, id: \.identifier) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.body)
                        Text(candidate.fireDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("notificationsList")
            }
        }
    }

    // MARK: - Widget (functional settings, not rendering — docs/09-screens-and-ux.md)

    private var widgetTab: some View {
        Form {
            if let widgetConfiguration = event.widgetConfiguration {
                Section {
                    Toggle("Enabled", isOn: Bindable(widgetConfiguration).isEnabled)
                        .accessibilityIdentifier("widgetEnabledToggle")
                    Picker("Widget Type", selection: Bindable(widgetConfiguration).widgetType) {
                        Text("Countdown").tag(WidgetType.countdown)
                        Text("Preparation").tag(WidgetType.preparation)
                        Text("Timeline").tag(WidgetType.timeline)
                        Text("Progress").tag(WidgetType.progress)
                        Text("Checklist").tag(WidgetType.checklist)
                    }
                    .accessibilityIdentifier("widgetTypePicker")
                    Toggle("Show Location", isOn: Bindable(widgetConfiguration).showLocation)
                } footer: {
                    Text("These control how a placed Home Screen widget renders this event. Turning it off removes this event from the widget's \"Next Up\" picks and its configuration list.")
                }
            } else {
                ContentUnavailableView(
                    "No Widget Configuration",
                    systemImage: "square.dashed",
                    description: Text("This event was created before widget defaults existed.")
                )
            }
        }
        // Requirement 9: any app-side mutation that could change what a placed widget shows
        // must save + tell WidgetKit to reload — these bindings write directly to the
        // @Model object with no other save point in this view.
        .onChange(of: event.widgetConfiguration?.isEnabled) { _, _ in saveAndReloadWidget() }
        .onChange(of: event.widgetConfiguration?.widgetType) { _, _ in saveAndReloadWidget() }
        .onChange(of: event.widgetConfiguration?.showLocation) { _, _ in saveAndReloadWidget() }
    }

    private func saveAndReloadWidget() {
        try? modelContext.save()
        EventActions.reloadWidget()
    }

    /// Kue 2.0 Phase 2, requirement 9 — all the actual decision-making (what's copied vs.
    /// reset, duplicate detection, notification/widget side effects) lives in
    /// `EventDuplicationService`; this view only presents whatever it returns.
    private func duplicateEvent() {
        isDuplicating = true
        Task {
            let outcome = await EventDuplicationService.duplicate(event, context: modelContext)
            isDuplicating = false
            duplicationPresentation = DuplicationPresentation(newEvent: outcome.newEvent, detectedDuplicate: outcome.detectedDuplicate)
        }
    }
}

#Preview {
    let container = ModelContainerFactory.makeInMemory()
    let event = KueEvent(title: "Preview Event", eventType: .interview, startDate: .now, estimatedDurationMinutes: 60, source: .manual)
    container.mainContext.insert(event)
    return NavigationStack {
        EventDetailView(event: event)
    }
    .modelContainer(container)
}
