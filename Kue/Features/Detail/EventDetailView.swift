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
import UserNotifications
import UIKit

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
    @Environment(\.calendarProvider) private var calendarProvider
    // Kue 2.0 Phase 7 — requirement 32/34: restrained, injectable haptic feedback. Never the
    // real Taptic Engine under `KueUITests` — see `KueHaptics.swift`.
    @Environment(\.kueHaptics) private var haptics
    // Kue 2.0 Phase 9 — `\.liveActivityManager` (Kue/Features/LiveActivity/), same DI seam as
    // every other Fake-under-UITests service.
    @Environment(\.liveActivityManager) private var liveActivityManager
    // Kue 2.0 Phase 10.1 — docs/25 "I.": `openURL` (not `UIApplication.shared`, which is
    // unavailable in application extensions and would break `KueShare`'s incidental compile
    // of this whole view hierarchy) is the SwiftUI-safe way to open System Settings.
    @Environment(\.openURL) private var openURL

    @State private var tab: DetailTab = .info
    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var isCustomizingSchedule = false
    @State private var isDuplicating = false
    @State private var duplicationPresentation: DuplicationPresentation?

    // MARK: Kue 2.0 Phase 4 — Calendar export/update (docs/18-calendar-integration.md).
    @State private var calendarLinkStatus: CalendarLinkStatus = .notLinked
    @State private var isChoosingExportCalendar = false
    @State private var isConfirmingCalendarUpdate = false
    @State private var isPerformingCalendarAction = false
    @State private var calendarErrorMessage: String?

    // MARK: Kue 2.0 Phase 9 — Live Activity focus (docs/23-live-activities-and-focus-mode.md "F.")
    @State private var focusedLiveActivityEventID: UUID?
    @State private var isPerformingLiveActivityAction = false
    @State private var isConfirmingLiveActivityReplacement = false
    @State private var replacementCurrentEventID: UUID?
    @State private var replacementCurrentEventTitle = ""
    @State private var liveActivityErrorMessage: String?

    // MARK: Kue 2.0 Phase 10.1 — docs/25 "I." Notification transparency: read fresh right
    // after the `.task` below's own reschedule pass, so `notificationsTab` shows what's
    // actually true, not what Kue merely intends.
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingNotificationIdentifiers: Set<String> = []

    // MARK: Kue 3.0 Phase 3 — docs/31. Custom-rule editing state for the Notifications tab.
    @State private var isAddingNotificationRule = false
    @State private var editingNotificationRule: NotificationRule?
    // Kue 3.0 Phase 7 — docs/35 "Per-event notification editor."
    @State private var overridingEventTypeDefault: NotificationRuleDefault?

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
                    haptics.play(.destructiveConfirmed)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteOccurrenceButton")
                Button("Delete This and Future Occurrences", role: .destructive) {
                    OccurrenceReconciliationService.deleteOccurrence(event, scope: .thisAndFuture, context: modelContext)
                    haptics.play(.destructiveConfirmed)
                    dismiss()
                }
                .accessibilityIdentifier("confirmDeleteThisAndFutureButton")
            } else {
                Button("Delete", role: .destructive) {
                    EventActions.delete(event, context: modelContext)
                    haptics.play(.destructiveConfirmed)
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
            // Kue 2.0 Phase 4 — a pure status read (requirement 26), never a network/EventKit
            // side effect a user didn't ask for; re-derived every time this screen appears.
            refreshCalendarStatus()
            focusedLiveActivityEventID = await liveActivityManager.focusedEventID()
            // Kue 2.0 Phase 10.1 — docs/25 "I.": read the two truths `notificationsTab` needs
            // to distinguish "Kue intends to remind you" from "this will actually fire." Last
            // in this task deliberately — these only feed the Notifications tab, not the Info
            // tab's Calendar/Live Activity state above, which other flows read as soon as this
            // screen appears and shouldn't wait behind two extra `UNUserNotificationCenter`
            // round trips for.
            notificationAuthorizationStatus = await SystemNotificationScheduler.shared.authorizationStatus()
            pendingNotificationIdentifiers = Set(await SystemNotificationScheduler.shared.pendingRequestIdentifiers())
        }
        .confirmationDialog(
            "Replace the Live Activity for \"\(replacementCurrentEventTitle)\" with this event?",
            isPresented: $isConfirmingLiveActivityReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { confirmReplaceLiveActivity() }
                .accessibilityIdentifier("confirmReplaceLiveActivityButton")
            // Kue 2.0 Phase 9 — the system-provided `role: .cancel` row doesn't carry a custom
            // `.accessibilityIdentifier` through to the accessibility tree (confirmed via the
            // UI test suite); tests match it by its "Cancel" label instead.
            Button("Cancel", role: .cancel) {}
        } message: {
            // Requirement C: never silently replace — name both events up front.
            Text("Kue tracks one event's Live Activity at a time.")
        }
        .alert("Live Activity", isPresented: Binding(get: { liveActivityErrorMessage != nil }, set: { if !$0 { liveActivityErrorMessage = nil } })) {
            Button("OK") { liveActivityErrorMessage = nil }
        } message: {
            Text(liveActivityErrorMessage ?? "")
        }
        .sheet(isPresented: $isChoosingExportCalendar) {
            CalendarDestinationPickerView(calendars: calendarProvider.writableCalendars()) { chosen in
                isChoosingExportCalendar = false
                exportToCalendar(chosen)
            }
        }
        .confirmationDialog(
            calendarActionDialogTitle,
            isPresented: $isConfirmingCalendarUpdate,
            titleVisibility: .visible
        ) {
            calendarActionDialogButtons
        } message: {
            if case .externallyModified(let live) = calendarLinkStatus {
                // Requirement 28/29 — a real conflict summary, never a vague warning; the user
                // must see what changed before choosing to overwrite it.
                Text("The Calendar event changed outside Kue:\n\"\(live.title)\", \(live.startDate.formatted(date: .abbreviated, time: .shortened)).\nOverwriting replaces those changes with Kue's current details.")
            }
        }
        .alert("Calendar Error", isPresented: Binding(get: { calendarErrorMessage != nil }, set: { if !$0 { calendarErrorMessage = nil } })) {
            Button("OK") { calendarErrorMessage = nil }
        } message: {
            Text(calendarErrorMessage ?? "")
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        Form {
            // Kue 2.0 Phase 7 — requirement 15's "clear title and event status" up front,
            // before the detail rows: a glanceable status badge plus, when this event has
            // generated tasks, the same preparation-progress readout Home's `EventCard` shows.
            Section {
                HStack {
                    EventStatusBadge(style: KueStatusStyle.forEvent(event, status: displayedStatus))
                    Spacer()
                }
                if !event.tasks.isEmpty && displayedStatus != .completed && displayedStatus != .cancelled && displayedStatus != .archived && displayedStatus != .awaitingOutcome {
                    PreparationProgressView(
                        completedCount: event.tasks.filter(\.isCompleted).count,
                        totalCount: event.tasks.count
                    )
                }
            }
            .listRowBackground(Color.clear)

            // Kue 2.0 Phase 10.1 — docs/25 "E." The one place a past, unconfirmed event is
            // asked about directly. Placed right after the status badge — the most prominent
            // spot on this screen short of the navigation title.
            if displayedStatus == .awaitingOutcome {
                // No identifier on the `Section` itself — a real bug found via UI testing:
                // `.accessibilityIdentifier` applied to a `Form` `Section` propagates down and
                // overrides each child's own identifier (every button inside reported
                // "outcomeCardSection" instead of its own), rather than labeling the section
                // as a distinct element. `outcomeCard`'s own buttons/text already carry their
                // own identifiers, which is all any caller (test or VoiceOver) actually needs.
                Section {
                    outcomeCard
                }
            }

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

            Section("Live Activity") {
                liveActivityFocusRow
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
                            haptics.play(.taskCompleted)
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

                calendarActionsSection

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
            }

            // Kue 2.0 Phase 7 — requirement 16: an irreversible action must not visually
            // compete with the reversible ones above it (Archive/Cancel/Skip can all be
            // undone; deleting an event, its tasks, schedule, and widget settings cannot).
            // A dedicated, clearly-labeled section is the plain-Form equivalent of iOS's own
            // "Danger Zone" convention — no different button role or color than before
            // (`role: .destructive` already rendered this red), just physically separated.
            Section {
                Button("Delete Event", role: .destructive) {
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier("deleteEventButton")
            } footer: {
                Text("This can't be undone.")
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
        case .awaitingOutcome: return "Needs Review"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .archived: return "Archived"
        }
    }

    private var dateStyle: Date.FormatStyle {
        event.isAllDay ? .dateTime.month().day().year() : .dateTime.month().day().year().hour().minute()
    }

    // MARK: - Kue 2.0 Phase 10.1 — outcome card (docs/25 "E.")

    /// "How did it go?" — the one place a past, unconfirmed event is asked directly.
    /// Completed/Reschedule/Skipped/Cancelled all reuse the exact same mutation functions the
    /// Actions section below already calls — no separate outcome-specific mutation logic.
    private var outcomeCard: some View {
        VStack(alignment: .leading, spacing: KueSpacing.sm) {
            Label("How did it go?", systemImage: "questionmark.circle")
                .font(KueTypography.cardTitle)
                .foregroundStyle(KueColor.warning)
            Text(outcomeTimingDescription)
                .font(KueTypography.footnote)
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("outcomeTimingDescription")

            HStack(spacing: KueSpacing.sm) {
                Button("Completed") {
                    EventActions.complete(event, context: modelContext)
                    haptics.play(.taskCompleted)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("outcomeCompletedButton")

                Button("Reschedule") { isEditing = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("outcomeRescheduleButton")
            }

            HStack(spacing: KueSpacing.sm) {
                // Occurrence-aware, same rule the Actions section's own Skip button follows.
                if event.seriesID != nil {
                    Button("Skipped") {
                        EventActions.skip(event, context: modelContext)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("outcomeSkippedButton")
                }
                // No extra confirmation dialog — matches the plain "Cancel Event" button below
                // exactly (reversible via Un-cancel; only Delete gets a blocking dialog).
                Button("Cancelled", role: .destructive) {
                    EventActions.cancel(event, context: modelContext)
                    haptics.play(.destructiveConfirmed)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("outcomeCancelledButton")
            }
        }
        .padding(.vertical, KueSpacing.xxs)
    }

    /// "Scheduled for ... · ended ..." — both read in the event's own pinned timezone, never
    /// the device's current one (docs/25 "E."). `RelativeDateTimeFormatter` compares absolute
    /// instants, so the "how long ago" half needs no explicit timezone of its own.
    private var outcomeTimingDescription: String {
        let pinnedZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        let base = Date.FormatStyle(timeZone: pinnedZone)
        let scheduledStyle = event.isAllDay
            ? base.month().day().year()
            : base.month().day().year().hour().minute()
        let scheduled = event.startDate.formatted(scheduledStyle)
        let elapsed = RelativeDateTimeFormatter().localizedString(for: event.effectiveEndDate, relativeTo: .now)
        return "Scheduled for \(scheduled) — ended \(elapsed)"
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
    /// Kue 2.0 Phase 10.1 — docs/25 "I.": never just list what Kue *intends* to schedule: an
    /// authorization-denied user or one whose Intensity/pending-cap excluded a reminder would
    /// read that as a promise Kue can't keep — the exact honesty gap this phase exists to
    /// close. `isNotificationsDisabled` gates a top banner; each row's own `notificationStatusText(for:)`
    /// distinguishes "scheduled," "time already passed," and "not currently scheduled" (the
    /// one honest umbrella for the pending-cap and scheduling-failure cases, which look
    /// identical from here — `add()` swallows its own errors, docs/08 "Permission handling").
    /// Kue 3.0 Phase 7 — docs/35 "Per-event notification editor." Re-runs the exact same
    /// `NotificationPlanner` a real `NotificationEngine.reschedule` pass would, scoped to just
    /// this one event, so every row below shows the *actual* calculated delivery date/
    /// suppression reason — never a re-derived summary that could silently disagree with what
    /// would really be scheduled.
    private func effectivePlan(intensity: NotificationIntensity) -> NotificationSchedulePlan {
        NotificationPlanner.plan(NotificationPlanner.Input(
            events: [event], globalPreferences: .current, eventTypeRules: .current,
            intensity: intensity, authorizationGranted: !isNotificationsDisabled, now: .now,
            capacity: NotificationEngine.pendingRequestCap
        ))
    }

    private var notificationsTab: some View {
        let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
        let allCandidates = NotificationCandidateBuilder.candidates(for: event)
        let visibleCandidates = NotificationCandidateBuilder.prioritized(
            NotificationCandidateBuilder.filter(allCandidates, intensity: intensity)
        )
        let excludedByIntensityCount = allCandidates.count - visibleCandidates.count
        let plan = effectivePlan(intensity: intensity)
        let eventLevelAnchors = Set(event.notificationRules.map(\.anchor))
        // Kue 3.0 Phase 7 — docs/35: the same precedence `NotificationPlanner` itself enforces
        // — an event-type default only shown here while nothing more specific overrides it.
        let effectiveEventTypeDefaults = EventTypeNotificationPreferences.current.rules(for: event.eventType)
            .filter { !eventLevelAnchors.contains($0.anchor.asRuleAnchor) }
        // Kue 3.0 Phase 3 — the Custom Rules section (and "Add Custom Rule…") is always
        // reachable, regardless of whether any *default* reminder currently exists — a real
        // bug found via a real `KueUITests` run: the section used to live only inside the
        // branch that also required `!visibleCandidates.isEmpty`, so an event with no default
        // reminders pending (or notifications not yet authorized) hid the add-a-rule
        // affordance entirely. Only the *default-reminders* half of this tab is conditional now.
        return List {
            if isNotificationsDisabled {
                Section {
                    Label("Notifications are off", systemImage: "bell.slash")
                        .foregroundStyle(KueColor.secondaryText)
                        .accessibilityIdentifier("notificationsDisabledLabel")
                    Button("Open Settings") { openSystemSettings() }
                        .accessibilityIdentifier("openSystemSettingsButton")
                } footer: {
                    Text("Kue can't guarantee reminders below fire until notifications are on.")
                }
            }

            // Kue 3.0 Phase 3 — docs/31: every rule shows its source (Event, here, vs.
            // Global Default below) — inherited and customized rules are never distinguished
            // by color alone (source is a text label on every row). Kue 3.0 Phase 7 — docs/35:
            // now also shows the actual calculated delivery date/suppression reason per rule,
            // computed from the real planner, never re-derived.
            Section {
                ForEach(event.notificationRules.sorted { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }) { rule in
                    Button {
                        editingNotificationRule = rule
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(customRuleLabel(rule))
                                Spacer()
                                if !rule.isEnabled {
                                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("Source: Event").font(.caption2).foregroundStyle(.secondary)
                            Text(planStatusText(for: rule.id, plan: plan))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Button("Add Custom Rule…") { isAddingNotificationRule = true }
                    .accessibilityIdentifier("addNotificationRuleButton")
            } header: {
                Text("Custom Rules")
            } footer: {
                Text("Custom rules replace the matching default below and are never affected by future changes to your global defaults.")
            }

            // Kue 3.0 Phase 7 — docs/35 "Per-event notification editor": inherited Event Type
            // rules, visually distinguished ("Source: \(eventType) Default") from this event's
            // own rules above — "Override" seeds a new event-level rule from it (which then
            // naturally supersedes it, matching `NotificationPlanner`'s own precedence) rather
            // than mutating the shared event-type default itself.
            if !effectiveEventTypeDefaults.isEmpty {
                Section {
                    ForEach(effectiveEventTypeDefaults) { def in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(eventTypeDefaultLabel(def))
                                Spacer()
                                if !def.isEnabled {
                                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Override") { overridingEventTypeDefault = def }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("overrideEventTypeDefaultButton")
                            }
                            Text("Source: \(event.eventType.displayName) Default").font(.caption2).foregroundStyle(.secondary)
                            Text(planStatusText(for: nil, identifier: "\(event.id)-eventtype-\(event.eventType.rawValue)-\(def.id)", plan: plan))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(event.eventType.displayName) Defaults")
                } footer: {
                    Text("Inherited from Settings → Notifications → Event Type Overrides. Overriding creates a rule just for this event.")
                }
            }

            if visibleCandidates.isEmpty {
                Section {
                    Text("Nothing left to remind you about for this event from your global defaults.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(visibleCandidates, id: \.identifier) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.body)
                            Text(notificationStatusText(for: candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Source: Global Default").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Default Reminders")
                } footer: {
                    if excludedByIntensityCount > 0 {
                        Text("\(excludedByIntensityCount) more reminder\(excludedByIntensityCount == 1 ? "" : "s") won't fire — excluded by your Intensity setting.")
                    }
                }
            }
        }
        .accessibilityIdentifier("notificationsList")
        .sheet(isPresented: $isAddingNotificationRule) {
            NotificationRuleEditorView(event: event)
        }
        .sheet(item: $editingNotificationRule) { rule in
            NotificationRuleEditorView(event: event, existingRule: rule)
        }
        .sheet(item: $overridingEventTypeDefault) { def in
            NotificationRuleEditorView(event: event, seedFromEventTypeDefault: def)
        }
    }

    /// Kue 3.0 Phase 7 — docs/35 "Per-event notification editor": "show the actual calculated
    /// delivery date/time; explain when a notification cannot be scheduled because its delivery
    /// time passed; show 'possibly capped' when system limits prevent certainty." Looks up this
    /// exact identifier/rule id in the real plan rather than re-deriving any of this.
    private func planStatusText(for ruleID: UUID?, identifier: String? = nil, plan: NotificationSchedulePlan) -> String {
        if let scheduled = plan.scheduledCandidates.first(where: { ruleID != nil ? $0.sourceRuleID == ruleID : $0.identifier == identifier }) {
            let dateText = scheduled.effectiveDeliveryDate.formatted(date: .abbreviated, time: .shortened)
            if scheduled.quietHoursAdjustment == .movedToQuietHoursEnd {
                return "Scheduled for \(dateText) — moved by quiet hours"
            }
            return "Scheduled for \(dateText)"
        }
        if let excluded = plan.excludedCandidates.first(where: { ruleID != nil ? $0.sourceRuleID == ruleID : $0.identifier == identifier }) {
            switch excluded.reason {
            case .systemCapacityLimit: return "Possibly capped — too many reminders pending"
            case .passed: return "Time already passed — won't fire"
            default: return excluded.explanation
            }
        }
        return "Not currently scheduled"
    }

    private func eventTypeDefaultLabel(_ def: NotificationRuleDefault) -> String {
        switch def.anchor {
        case .eventStart: return def.offsetDirection == .at ? "At event start" : "\(def.offsetQuantity) \(def.offsetUnit.rawValue) \(def.offsetDirection == .before ? "before" : "after") start"
        case .eventEnd: return def.offsetDirection == .at ? "At event end" : "\(def.offsetQuantity) \(def.offsetUnit.rawValue) \(def.offsetDirection == .before ? "before" : "after") end"
        case .outcomeFollowUp: return "Outcome follow-up"
        }
    }

    private func customRuleLabel(_ rule: NotificationRule) -> String {
        switch rule.anchor {
        case .eventStart: return rule.offsetDirection == .at ? "At event start" : "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") start"
        case .eventEnd: return rule.offsetDirection == .at ? "At event end" : "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") end"
        case .outcomeFollowUp: return "Outcome follow-up"
        case .taskDue: return "Task reminder"
        case .absolute: return rule.absoluteDate?.formatted(date: .abbreviated, time: .shortened) ?? "Custom date"
        }
    }

    private var isNotificationsDisabled: Bool {
        notificationAuthorizationStatus == .denied || notificationAuthorizationStatus == .notDetermined
    }

    private func notificationStatusText(for candidate: NotificationCandidate, now: Date = .now) -> String {
        if isNotificationsDisabled {
            return "Won't fire — notifications are off"
        }
        if candidate.fireDate <= now {
            return "Reminder time has passed"
        }
        if pendingNotificationIdentifiers.contains(candidate.identifier) {
            return "Scheduled for \(candidate.fireDate.formatted(date: .abbreviated, time: .shortened))"
        }
        // Never claim delivery Kue can't confirm — docs/25 "I.": distinguish "submitted
        // pending" from "authorized" from "actually delivered," which no app can guarantee.
        return "Not currently scheduled — may be past Kue's reminder limit"
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
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

    // MARK: - Kue 2.0 Phase 9 — Live Activity focus (docs/23-live-activities-and-focus-mode.md "F.")

    /// One-event focus policy, surfaced directly: this event's own activity (refresh/stop),
    /// starting fresh, or — reusing the exact same eligibility rule the Dedicated Countdown
    /// widget already uses (`WidgetContentService.isEligibleForDedicatedSelection`) — an
    /// honest "not eligible" note for a terminal/archived event, never an offer that would fail.
    @ViewBuilder
    private var liveActivityFocusRow: some View {
        if focusedLiveActivityEventID == event.id {
            Label("Live Activity Active", systemImage: "bolt.fill")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("liveActivityActiveLabel")
            Button("Refresh") {
                performLiveActivityAction { await liveActivityManager.update(for: event, now: .now) }
            }
            .disabled(isPerformingLiveActivityAction)
            Button("Stop Live Activity", role: .destructive) {
                performLiveActivityAction {
                    await LiveActivityFocusCoordinator.stopFocus(eventID: event.id, manager: liveActivityManager)
                    focusedLiveActivityEventID = nil
                }
            }
            .accessibilityIdentifier("stopLiveActivityButton")
            .disabled(isPerformingLiveActivityAction)
        } else if WidgetContentService.isEligibleForDedicatedSelection(event) {
            Button {
                performLiveActivityAction { await startLiveActivity() }
            } label: {
                if isPerformingLiveActivityAction {
                    ProgressView()
                } else {
                    Text("Start Live Activity")
                }
            }
            .accessibilityIdentifier("startLiveActivityButton")
            .disabled(isPerformingLiveActivityAction || !liveActivityManager.isAvailable)
            if !liveActivityManager.isAvailable {
                Text("Live Activities are turned off. Enable them in Settings to track this event on the Lock Screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("This event isn't currently eligible for a Live Activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func performLiveActivityAction(_ action: @escaping () async -> Void) {
        isPerformingLiveActivityAction = true
        Task {
            await action()
            isPerformingLiveActivityAction = false
        }
    }

    private func startLiveActivity() async {
        switch await LiveActivityFocusCoordinator.requestFocus(for: event, manager: liveActivityManager) {
        case .started, .alreadyActiveForThisEvent:
            focusedLiveActivityEventID = event.id
        case .needsReplacementConfirmation(let currentEventID):
            replacementCurrentEventID = currentEventID
            replacementCurrentEventTitle = (try? modelContext.fetch(
                FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == currentEventID })
            ))?.first?.title ?? "another event"
            isConfirmingLiveActivityReplacement = true
        case .unavailable(let reason):
            liveActivityErrorMessage = Self.liveActivityUnavailableMessage(reason)
        }
    }

    /// Only reachable after the user explicitly tapped "Replace" in the confirmation dialog
    /// above — never invoked automatically (requirement C).
    private func confirmReplaceLiveActivity() {
        guard let currentEventID = replacementCurrentEventID else { return }
        performLiveActivityAction {
            switch await LiveActivityFocusCoordinator.replaceFocus(currentEventID: currentEventID, with: event, manager: liveActivityManager) {
            case .started, .alreadyActiveForThisEvent:
                focusedLiveActivityEventID = event.id
            case .unavailable(let reason):
                liveActivityErrorMessage = Self.liveActivityUnavailableMessage(reason)
            case .needsReplacementConfirmation:
                break // can't recur — the old activity was already ended above
            }
        }
    }

    private static func liveActivityUnavailableMessage(_ reason: LiveActivityUnavailableReason) -> String {
        switch reason {
        case .authorizationDisabled:
            return "Live Activities are turned off. Enable them in Settings to track this event on the Lock Screen."
        case .unsupported:
            return "Live Activities aren't supported on this device."
        case .anotherEventAlreadyFocused:
            return "Another event's Live Activity is already active."
        case .requestFailed:
            return "Couldn't start the Live Activity. Try again."
        }
    }

    // MARK: - Kue 2.0 Phase 4 — Calendar export/update (docs/18-calendar-integration.md)

    /// Requirement 17/24 — "Add to Apple Calendar" only offered when not yet linked;
    /// "Update Calendar Event" (plus a link-status row and Unlink) only once it is.
    @ViewBuilder
    private var calendarActionsSection: some View {
        if event.externalCalendarEventIdentifier == nil {
            Button {
                isChoosingExportCalendar = true
            } label: {
                if isPerformingCalendarAction {
                    ProgressView()
                } else {
                    Text("Add to Apple Calendar")
                }
            }
            .accessibilityIdentifier("addToCalendarButton")
            .disabled(isPerformingCalendarAction || !calendarProvider.authorizationState().canWriteEvents)
        } else {
            calendarLinkStatusRow

            Button {
                refreshCalendarStatus()
                isConfirmingCalendarUpdate = true
            } label: {
                if isPerformingCalendarAction {
                    ProgressView()
                } else {
                    Text("Update Calendar Event")
                }
            }
            .accessibilityIdentifier("updateCalendarEventButton")
            .disabled(isPerformingCalendarAction)

            Button("Unlink from Calendar") {
                CalendarExportService.unlink(event, context: modelContext)
                calendarLinkStatus = .notLinked
            }
            .accessibilityIdentifier("unlinkCalendarEventButton")
        }
    }

    @ViewBuilder
    private var calendarLinkStatusRow: some View {
        switch calendarLinkStatus {
        case .notLinked:
            EmptyView()
        case .linked:
            Label("Linked to \(event.externalCalendarTitle ?? "Calendar")", systemImage: "calendar.badge.checkmark")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("calendarLinkStatusLinked")
        case .missing:
            Label("Calendar event can't be found", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("calendarLinkStatusMissing")
        case .externallyModified:
            Label("Calendar event changed externally", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("calendarLinkStatusExternallyModified")
        }
    }

    private var calendarActionDialogTitle: String {
        switch calendarLinkStatus {
        case .missing:
            return "The linked Calendar event can't be found. Recreate it, or unlink it from this Kue event?"
        case .externallyModified:
            return "This Calendar event changed outside Kue."
        default:
            return "Update the linked Calendar event with this event's current details?"
        }
    }

    @ViewBuilder
    private var calendarActionDialogButtons: some View {
        switch calendarLinkStatus {
        case .missing:
            // Requirement 27 — exactly the three offered choices.
            Button("Recreate Calendar Event") { recreateCalendarEvent() }
                .accessibilityIdentifier("recreateCalendarEventButton")
            Button("Unlink", role: .destructive) {
                CalendarExportService.unlink(event, context: modelContext)
                calendarLinkStatus = .notLinked
            }
            .accessibilityIdentifier("unlinkFromMissingDialogButton")
        case .externallyModified:
            // Requirement 28/29 — proceeding is always an explicit, named choice; there is no
            // path that overwrites without this exact tap.
            Button("Overwrite with Kue's Version", role: .destructive) { updateCalendarEvent() }
                .accessibilityIdentifier("overwriteCalendarEventButton")
        default:
            Button("Update") { updateCalendarEvent() }
                .accessibilityIdentifier("confirmUpdateCalendarEventButton")
        }
    }

    private func refreshCalendarStatus() {
        guard event.externalCalendarEventIdentifier != nil else { calendarLinkStatus = .notLinked; return }
        calendarLinkStatus = CalendarExportService.status(for: event, provider: calendarProvider)
    }

    private func exportToCalendar(_ calendar: KueWritableCalendar) {
        isPerformingCalendarAction = true
        let result = CalendarExportService.export(event, to: calendar, provider: calendarProvider, context: modelContext)
        isPerformingCalendarAction = false
        handle(result)
    }

    private func updateCalendarEvent() {
        isPerformingCalendarAction = true
        let result = CalendarExportService.update(event, provider: calendarProvider, context: modelContext)
        isPerformingCalendarAction = false
        handle(result)
    }

    private func recreateCalendarEvent() {
        isPerformingCalendarAction = true
        let result = CalendarExportService.recreate(event, provider: calendarProvider, context: modelContext)
        isPerformingCalendarAction = false
        handle(result)
    }

    private func handle(_ result: Result<Void, CalendarOperationError>) {
        switch result {
        case .success:
            refreshCalendarStatus()
        case .failure(let error):
            // Requirement: "Calendar failures must never damage Kue data" — nothing about
            // `event` changed; this only surfaces the specific failure.
            calendarErrorMessage = error.errorDescription
        }
    }
}

private func previewEvent(withTasks: Bool = false) -> (ModelContainer, KueEvent) {
    let container = ModelContainerFactory.makeInMemory()
    let event = KueEvent(title: "Preview Event", eventType: .interview, startDate: .now, estimatedDurationMinutes: 60, source: .manual)
    container.mainContext.insert(event)
    if withTasks {
        let task = KueTask(event: event, title: "Review resume", dueDate: .now, isCompleted: true, offsetLabel: "1 day before")
        container.mainContext.insert(task)
        event.tasks = [task]
    }
    return (container, event)
}

#Preview("Event Detail — Light") {
    let (container, event) = previewEvent(withTasks: true)
    return NavigationStack { EventDetailView(event: event) }
        .modelContainer(container)
}

#Preview("Event Detail — Dark") {
    let (container, event) = previewEvent(withTasks: true)
    return NavigationStack { EventDetailView(event: event) }
        .modelContainer(container)
        .preferredColorScheme(.dark)
}

#Preview("Event Detail — Large Dynamic Type") {
    let (container, event) = previewEvent(withTasks: true)
    return NavigationStack { EventDetailView(event: event) }
        .modelContainer(container)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
