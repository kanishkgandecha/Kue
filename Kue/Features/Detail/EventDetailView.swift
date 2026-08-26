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
        .confirmationDialog(
            "Delete \"\(event.title)\"? This removes its tasks, schedule, and widget settings too.",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                EventActions.delete(event, context: modelContext)
                dismiss()
            }
            .accessibilityIdentifier("confirmDeleteButton")
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
            }

            if let notes = event.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section("Actions") {
                if displayedStatus == .archived {
                    Button("Unarchive") {
                        EventActions.unarchive(event, context: modelContext)
                    }
                    .accessibilityIdentifier("unarchiveEventButton")
                } else {
                    if event.isCancelled {
                        Button("Un-cancel") {
                            EventActions.uncancel(event, context: modelContext)
                        }
                    } else {
                        Button("Cancel Event", role: .destructive) {
                            EventActions.cancel(event, context: modelContext)
                        }
                        .accessibilityIdentifier("cancelEventButton")
                    }

                    if event.isManuallyCompleted {
                        Button("Mark Not Complete") {
                            EventActions.uncomplete(event, context: modelContext)
                        }
                    } else {
                        Button("Mark Complete") {
                            EventActions.complete(event, context: modelContext)
                        }
                        .accessibilityIdentifier("completeEventButton")
                    }

                    Button("Archive") {
                        EventActions.archive(event, context: modelContext)
                    }
                    .accessibilityIdentifier("archiveEventButton")
                }

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

    // MARK: - Timeline / Tasks / Notifications (restrained empty states — later phases)

    private var timelineTab: some View {
        ContentUnavailableView(
            "No Preparation Timeline Yet",
            systemImage: "calendar.badge.clock",
            description: Text("The scheduling engine arrives in Phase 3.")
        )
    }

    private var tasksTab: some View {
        Group {
            if event.tasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks Yet",
                    systemImage: "checklist",
                    description: Text("Preparation tasks are generated once scheduling arrives in Phase 3.")
                )
            } else {
                List(event.tasks.sorted(by: { $0.sortOrder < $1.sortOrder })) { task in
                    HStack {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        Text(task.title)
                    }
                }
            }
        }
    }

    private var notificationsTab: some View {
        ContentUnavailableView(
            "No Notifications Yet",
            systemImage: "bell",
            description: Text("Reminders arrive in Phase 8.")
        )
    }

    // MARK: - Widget (functional settings, not rendering — docs/09-screens-and-ux.md)

    private var widgetTab: some View {
        Form {
            if let widgetConfiguration = event.widgetConfiguration {
                Section {
                    Toggle("Enabled", isOn: Bindable(widgetConfiguration).isEnabled)
                    Picker("Widget Type", selection: Bindable(widgetConfiguration).widgetType) {
                        Text("Countdown").tag(WidgetType.countdown)
                        Text("Preparation").tag(WidgetType.preparation)
                        Text("Timeline").tag(WidgetType.timeline)
                        Text("Progress").tag(WidgetType.progress)
                        Text("Checklist").tag(WidgetType.checklist)
                    }
                    Toggle("Show Location", isOn: Bindable(widgetConfiguration).showLocation)
                } footer: {
                    Text("These control how a placed Home Screen widget would render this event. Widgets themselves arrive in Phase 4.")
                }
            } else {
                ContentUnavailableView(
                    "No Widget Configuration",
                    systemImage: "square.dashed",
                    description: Text("This event was created before widget defaults existed.")
                )
            }
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
