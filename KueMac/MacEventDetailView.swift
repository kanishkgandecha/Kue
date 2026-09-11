//
//  MacEventDetailView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — native Mac Event Detail. Organized detail sections (not an enlarged
//  iPhone sheet — no tab bar, no full-screen modal). Every mutation reuses `EventActions`/
//  `EventStatusEngine`/`WidgetIntentActions`/`TaskEditingService` (Shared/) — nothing here
//  re-derives lifecycle or duplicates a mutation.
//

import SwiftUI
import SwiftData

struct MacEventDetailView: View {
    @Bindable var event: KueEvent
    var onDeleted: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendarProvider) private var calendarProvider
    @State private var isPresentingEditor = false
    @State private var isConfirmingDelete = false
    @State private var deleteScope: RecurrenceEditScope = .thisOccurrence
    @State private var isAddingTask = false
    @State private var newTaskTitle = ""
    @State private var newTaskDueDate = Date()
    @State private var isChoosingCalendar = false
    @State private var calendarAlertMessage: String?
    /// Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification Studio parity". `.some(nil)`
    /// presents the editor for a brand-new rule; `.some(.some(rule))` edits `rule`; `nil`
    /// dismissed. Matches `MacEventEditorView`'s own `.sheet(item:)`-free optional-Bool pattern
    /// used elsewhere in this file, just one level deeper since "new" and "not presented" must
    /// stay distinguishable.
    @State private var isPresentingNewNotificationRule = false
    @State private var editingNotificationRule: NotificationRule?

    private var status: EventStatus { EventStatusEngine.derive(for: event) }
    private var sortedTasks: [KueTask] { event.tasks.sorted { $0.sortOrder < $1.sortOrder } }

    var body: some View {
        Form {
            headerSection
            if status == .awaitingOutcome {
                outcomeSection
            }
            actionsSection
            tasksSection
            notificationsSection
            calendarSection
            if event.seriesID != nil {
                recurrenceSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(event.title.isEmpty ? "Event" : event.title)
        .toolbar {
            ToolbarItem {
                Button("Edit", systemImage: "pencil") { isPresentingEditor = true }
                    .accessibilityIdentifier("editEventButton")
            }
            ToolbarItem {
                Button("Delete", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                    .accessibilityIdentifier("deleteEventButton")
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            MacEventEditorView(mode: .edit(event)) { _ in }
        }
        .sheet(isPresented: $isChoosingCalendar) {
            MacCalendarDestinationPickerView(calendars: calendarProvider.writableCalendars()) { calendar in
                export(to: calendar)
            }
        }
        .sheet(isPresented: $isPresentingNewNotificationRule) {
            MacNotificationRuleEditorView(event: event)
        }
        .sheet(item: $editingNotificationRule) { rule in
            MacNotificationRuleEditorView(event: event, existingRule: rule)
        }
        .alert("Calendar", isPresented: Binding(get: { calendarAlertMessage != nil }, set: { if !$0 { calendarAlertMessage = nil } })) {
            Button("OK") { calendarAlertMessage = nil }
        } message: {
            Text(calendarAlertMessage ?? "")
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            if event.seriesID != nil {
                Picker("Scope", selection: $deleteScope) {
                    Text("This Event").tag(RecurrenceEditScope.thisOccurrence)
                    Text("This and Future Events").tag(RecurrenceEditScope.thisAndFuture)
                }
            }
            Button("Delete", role: .destructive) { performDelete() }
                .accessibilityIdentifier("confirmDeleteEventButton")
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            LabeledContent("Type", value: event.eventType.displayName)
            LabeledContent("Starts", value: event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
            if let endDate = event.endDate {
                LabeledContent("Ends", value: endDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
            }
            LabeledContent("Status", value: statusText)
            if let location = event.location, !location.isEmpty {
                LabeledContent("Location", value: location)
            }
            if let notes = event.notes, !notes.isEmpty {
                Text(notes).font(.callout)
            }
        }
    }

    private var statusText: String {
        switch status {
        case .draft: return "Draft"
        case .upcoming: return "Upcoming"
        case .preparing: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .active: return "Active"
        case .awaitingOutcome: return "Needs Review"
        case .completed: return "Completed"
        case .cancelled: return event.isSkipped ? "Skipped" : "Cancelled"
        case .archived: return "Archived"
        }
    }

    // MARK: - Outcome (docs/25 — never auto-completed by passing time)

    private var outcomeSection: some View {
        Section("How did it go?") {
            Button("Mark Complete") { EventActions.complete(event, context: modelContext) }
            Button("Skip") { EventActions.skip(event, context: modelContext) }
            Button("Cancel", role: .destructive) { EventActions.cancel(event, context: modelContext) }
        }
    }

    // MARK: - Reversible actions

    @ViewBuilder
    private var actionsSection: some View {
        Section("Actions") {
            if status == .archived {
                Button("Unarchive") { Task { await EventActions.unarchive(event, context: modelContext) } }
            } else {
                if event.isCancelled {
                    Button("Uncancel") { Task { await EventActions.uncancel(event, context: modelContext) } }
                } else if event.isManuallyCompleted {
                    Button("Mark Incomplete") { Task { await EventActions.uncomplete(event, context: modelContext) } }
                } else if event.isSkipped {
                    Button("Unskip") { Task { await EventActions.unskip(event, context: modelContext) } }
                } else if status != .awaitingOutcome {
                    Button("Mark Complete") { EventActions.complete(event, context: modelContext) }
                    Button("Skip") { EventActions.skip(event, context: modelContext) }
                    Button("Cancel", role: .destructive) { EventActions.cancel(event, context: modelContext) }
                }
                Button("Archive") { EventActions.archive(event, context: modelContext) }
            }
        }
    }

    // MARK: - Tasks (Kue 3.0 Phase 1 — first in-app task management anywhere in Kue)

    private var tasksSection: some View {
        Section("Preparation Tasks (\(event.tasks.filter(\.isCompleted).count)/\(event.tasks.count))") {
            if sortedTasks.isEmpty {
                Text("No tasks yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(sortedTasks.enumerated()), id: \.element.id) { index, task in
                    taskRow(task, index: index, count: sortedTasks.count)
                }
                .onMove { indices, newOffset in
                    var reordered = sortedTasks
                    reordered.move(fromOffsets: indices, toOffset: newOffset)
                    TaskEditingService.reorderTasks(reordered, context: modelContext)
                }
            }
            if isAddingTask {
                HStack {
                    TextField("Task title", text: $newTaskTitle)
                    DatePicker("Due", selection: $newTaskDueDate, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                    Button("Add") {
                        guard !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        TaskEditingService.addTask(title: newTaskTitle, dueDate: newTaskDueDate, to: event, context: modelContext)
                        newTaskTitle = ""
                        isAddingTask = false
                    }
                    Button("Cancel") { isAddingTask = false }
                }
            } else {
                Button("Add Task", systemImage: "plus") {
                    newTaskDueDate = event.startDate
                    isAddingTask = true
                }
            }
        }
    }

    /// Kue 3.0 Phase 1 cleanup — reordering was drag-only (`.onMove`) at first, which
    /// `List`'s own accessibility affordances (the VoiceOver rotor) can drive without a
    /// pointer, but leaves nothing reachable by plain `Tab`/`Space` keyboard navigation, the
    /// primary way a sighted keyboard-only user (not a VoiceOver user) reorders anything on
    /// Mac. These two buttons are real `Button`s — inherently `Tab`-focusable and
    /// `Space`/`Return`-activatable, no custom key-handling needed — calling the exact same
    /// `TaskEditingService.reorderTasks` the drag gesture already uses; disabled (not hidden)
    /// at the ends of the list rather than silently doing nothing.
    private func taskRow(_ task: KueTask, index: Int, count: Int) -> some View {
        HStack {
            VStack(spacing: 0) {
                Button {
                    moveTask(at: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel("Move Up")
                .accessibilityIdentifier("moveTaskUpButton-\(task.id)")

                Button {
                    moveTask(at: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
                .accessibilityLabel("Move Down")
                .accessibilityIdentifier("moveTaskDownButton-\(task.id)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                if task.isCompleted {
                    TaskEditingService.uncompleteTask(task, context: modelContext)
                } else {
                    Task {
                        try? await WidgetIntentActions.completeTask(
                            taskID: task.id, context: modelContext,
                            scheduler: SystemNotificationScheduler.shared, widgetReloader: SystemWidgetReloader.shared
                        )
                    }
                }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)

            TextField("Task title", text: Binding(
                get: { task.title },
                set: { TaskEditingService.renameTask(task, title: $0, context: modelContext) }
            ))
            .textFieldStyle(.plain)
            .strikethrough(task.isCompleted)
            .foregroundStyle(task.isCompleted ? .secondary : .primary)

            Spacer()
            Text(task.dueDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                TaskEditingService.deleteTask(task, context: modelContext)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
    }

    private func moveTask(at index: Int, by offset: Int) {
        var reordered = sortedTasks
        let target = index + offset
        guard reordered.indices.contains(index), reordered.indices.contains(target) else { return }
        reordered.swapAt(index, target)
        TaskEditingService.reorderTasks(reordered, context: modelContext)
    }

    // MARK: - Notifications

    /// Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification Studio parity": the full
    /// add/edit/delete/duplicate rule editor (`MacNotificationRuleEditorView`), reachable
    /// natively here — no iPhone-only gap left in this section. Every custom `NotificationRule`
    /// this event owns (source: Event) is tappable to edit, and carries a context menu for
    /// duplicate/delete; the default reminders below it (source: Global Default) stay
    /// read-only, matching iPhone's own `EventDetailView` "Custom Rules" vs. default-candidates
    /// split.
    private var notificationsSection: some View {
        let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
        let candidates = NotificationCandidateBuilder.prioritized(
            NotificationCandidateBuilder.filter(NotificationCandidateBuilder.candidates(for: event), intensity: intensity)
        )
        return Section("Notifications") {
            if !event.notificationRules.isEmpty {
                ForEach(event.notificationRules.sorted { $0.createdAt < $1.createdAt }) { rule in
                    Button {
                        editingNotificationRule = rule
                    } label: {
                        HStack {
                            Text(macCustomRuleLabel(rule))
                            Spacer()
                            Text(rule.isEnabled ? "Source: Event" : "Disabled")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") { editingNotificationRule = rule }
                        Button("Duplicate") { duplicateNotificationRule(rule) }
                        Button("Delete", role: .destructive) { deleteNotificationRule(rule) }
                    }
                }
            }
            if candidates.isEmpty && event.notificationRules.isEmpty {
                Text("No upcoming notifications for this event.").foregroundStyle(.secondary)
            } else {
                ForEach(candidates, id: \.identifier) { candidate in
                    VStack(alignment: .leading) {
                        Text(candidate.body)
                        HStack {
                            Text(candidate.fireDate.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text("Source: Global Default")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Add Notification Rule…") { isPresentingNewNotificationRule = true }
                .accessibilityIdentifier("addNotificationRuleButton")
        }
    }

    private func duplicateNotificationRule(_ rule: NotificationRule) {
        let copy = NotificationRule(
            event: rule.event, task: rule.task, anchor: rule.anchor, offsetDirection: rule.offsetDirection,
            offsetQuantity: rule.offsetQuantity, offsetUnit: rule.offsetUnit, absoluteDate: rule.absoluteDate,
            isEnabled: rule.isEnabled, customTitle: rule.customTitle, customBody: rule.customBody,
            sound: rule.sound, interruptionPreference: rule.interruptionPreference, snoozeMinutes: rule.snoozeMinutes
        )
        modelContext.insert(copy)
        event.notificationRules.append(copy)
        try? modelContext.save()
        Task {
            await NotificationEngine.reschedule(
                context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity,
                scheduler: SystemNotificationScheduler.shared
            )
        }
    }

    private func deleteNotificationRule(_ rule: NotificationRule) {
        modelContext.delete(rule)
        try? modelContext.save()
        Task {
            await NotificationEngine.reschedule(
                context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity,
                scheduler: SystemNotificationScheduler.shared
            )
        }
    }

    private func macCustomRuleLabel(_ rule: NotificationRule) -> String {
        switch rule.anchor {
        case .eventStart: return rule.offsetDirection == .at ? "At event start" : "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") start"
        case .eventEnd: return rule.offsetDirection == .at ? "At event end" : "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") end"
        case .outcomeFollowUp: return "Outcome follow-up"
        case .taskDue: return "Task reminder"
        case .absolute: return rule.absoluteDate?.formatted(date: .abbreviated, time: .shortened) ?? "Custom date"
        }
    }

    // MARK: - Calendar (Kue 3.0 Phase 1 cleanup — see docs/29 "Calendar". Reuses
    // `CalendarExportService`/`CalendarProviding` verbatim, the exact contract iOS's own
    // `EventDetailView` Calendar section already uses — never a re-derived export/link
    // policy.)

    @ViewBuilder
    private var calendarSection: some View {
        Section("Apple Calendar") {
            switch calendarLinkStatus {
            case .notLinked:
                Button("Add to Apple Calendar") { isChoosingCalendar = true }
                    .disabled(!calendarProvider.authorizationState().canWriteEvents)
            case .linked:
                if let title = event.externalCalendarTitle, !title.isEmpty {
                    LabeledContent("Linked To", value: title)
                }
                Button("Update Calendar Event") { update() }
                Button("Unlink", role: .destructive) { unlink() }
            case .missing:
                Text("The linked Calendar event can no longer be found.").foregroundStyle(.secondary)
                Button("Recreate in Apple Calendar") { recreate() }
                Button("Unlink", role: .destructive) { unlink() }
            case .externallyModified:
                Text("This event was changed in Apple Calendar since Kue last synced it.").foregroundStyle(.secondary)
                Button("Overwrite With Kue's Version") { update() }
                Button("Unlink", role: .destructive) { unlink() }
            }
            if !calendarProvider.authorizationState().canWriteEvents, calendarLinkStatus == .notLinked {
                Text("Calendar access isn't on — allow it in Settings ▸ Calendar to export events.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var calendarLinkStatus: CalendarLinkStatus {
        CalendarExportService.status(for: event, provider: calendarProvider)
    }

    private func export(to calendar: KueWritableCalendar) {
        switch CalendarExportService.export(event, to: calendar, provider: calendarProvider, context: modelContext) {
        case .success: break
        case .failure(let error): calendarAlertMessage = error.errorDescription
        }
    }

    private func update() {
        switch CalendarExportService.update(event, provider: calendarProvider, context: modelContext) {
        case .success: break
        case .failure(let error): calendarAlertMessage = error.errorDescription
        }
    }

    private func recreate() {
        switch CalendarExportService.recreate(event, provider: calendarProvider, context: modelContext) {
        case .success: break
        case .failure(let error): calendarAlertMessage = error.errorDescription
        }
    }

    private func unlink() {
        CalendarExportService.unlink(event, context: modelContext)
    }

    // MARK: - Recurrence

    private var recurrenceSection: some View {
        Section("Recurrence") {
            if let rule = event.recurrence {
                Text(rule.summary(startDate: event.recurrenceAnchorDate ?? event.startDate))
            }
            Text(event.isRecurrenceException ? "This event was edited independently of the series." : "Follows the series schedule.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deleteConfirmationTitle: String {
        event.seriesID != nil ? "Delete this recurring event?" : "Delete “\(event.title)”?"
    }

    private func performDelete() {
        if event.seriesID != nil {
            OccurrenceReconciliationService.deleteOccurrence(event, scope: deleteScope, context: modelContext)
        } else {
            EventActions.delete(event, context: modelContext)
        }
        onDeleted()
    }
}
