//
//  SettingsView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Settings": AI on/off, notification intensity, appearance,
//  privacy controls arrive alongside the phases that back them. Phase 8 (M7) added the
//  notifications section — docs/08-notifications.md "User control over intensity" and
//  docs/13-error-handling.md "Notification permission denied" (persistent, non-nagging
//  indicator, not a repeated prompt). Phase 10 (M9) audit added AI on/off
//  (`UserPreference.aiParsingEnabled`, declared since Phase 1 but never wired to anything)
//  and Privacy's "delete everything" (docs/11-privacy-and-offline.md — required, not
//  optional). Appearance remains unbuilt — V1 doesn't specify what it would even control
//  beyond the system's own light/dark setting, so there's nothing concrete to add yet.
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendarProvider) private var calendarProvider
    // Kue 2.0 Phase 7 — requirement 32/34: the one destructive confirmation this screen has.
    @Environment(\.kueHaptics) private var haptics
    // Kue 2.0 Phase 9 — same DI seam Event Detail's Focus section reads.
    @Environment(\.liveActivityManager) private var liveActivityManager
    @State private var preference: UserPreference?
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isConfirmingDeleteEverything = false
    // Kue 2.0 Phase 4 — Calendar section (docs/18-calendar-integration.md "Settings").
    @State private var calendarAuthorizationState: CalendarAuthorizationState = .notDetermined
    @State private var isRequestingCalendarAccess = false

    // MARK: Kue 2.0 Phase 9 — Live Activity focus management (docs/23 "F./I.")
    @State private var focusedLiveActivityEvent: KueEvent?
    @State private var isPerformingLiveActivityAction = false
    @State private var showLiveActivityTitle = LiveActivityPrivacyPreference.current.showTitle
    @State private var showLiveActivityNextTask = LiveActivityPrivacyPreference.current.showNextTask

    /// Injected for tests (requirement 10) — the live default is what KueApp effectively
    /// uses everywhere else.
    var scheduler: NotificationScheduling = SystemNotificationScheduler.shared
    var widgetReloader: WidgetReloading = SystemWidgetReloader.shared

    var body: some View {
        Form {
            Section {
                permissionStatusRow
            } header: {
                Text("Notifications")
            } footer: {
                if authorizationStatus == .denied {
                    // docs/13-error-handling.md "Notification permission denied" — exact copy.
                    Text("Notifications are off — enable in System Settings to get reminders")
                }
            }

            if let preference {
                Section {
                    Picker("Intensity", selection: Binding(
                        get: { preference.notificationIntensity },
                        set: { newValue in
                            preference.notificationIntensity = newValue
                            try? modelContext.save()
                            Task { await reschedule(intensity: newValue) }
                        }
                    )) {
                        Text("Minimal").tag(NotificationIntensity.minimal)
                        Text("Standard").tag(NotificationIntensity.standard)
                        Text("All").tag(NotificationIntensity.all)
                    }
                    .accessibilityIdentifier("notificationIntensityPicker")
                } footer: {
                    Text(intensityDescription(preference.notificationIntensity))
                }

                Section {
                    Toggle("Enable AI Parsing", isOn: Binding(
                        get: { preference.aiParsingEnabled },
                        set: { newValue in
                            preference.aiParsingEnabled = newValue
                            try? modelContext.save()
                        }
                    ))
                    .accessibilityIdentifier("aiParsingToggle")
                } header: {
                    Text("AI")
                } footer: {
                    // docs/03-data-model.md "UserPreference": "User can force manual-only entry."
                    Text("When off, Add and Share only offer the manual form — no natural-language parsing, typed or shared.")
                }
            }

            Section {
                calendarStatusRow
                if calendarAuthorizationState == .notDetermined {
                    Button {
                        Task { await requestCalendarAccess() }
                    } label: {
                        if isRequestingCalendarAccess {
                            ProgressView()
                        } else {
                            Text("Allow Calendar Access")
                        }
                    }
                    .accessibilityIdentifier("requestCalendarAccessButton")
                    .disabled(isRequestingCalendarAccess)
                }
            } header: {
                Text("Calendar")
            } footer: {
                if let explanation = calendarAuthorizationState.explanation {
                    Text(explanation)
                }
            }

            // Kue 2.0 Phase 10 — docs/24 "L." Not a new bottom tab; reached from here exactly
            // like every other Settings sub-surface (Calendar/Live Activity above).
            Section {
                NavigationLink {
                    SystemIntegrationSettingsView()
                } label: {
                    Label("Siri, Shortcuts & Spotlight", systemImage: "mic.circle")
                }
                .accessibilityIdentifier("systemIntegrationSettingsLink")
            } footer: {
                Text("Create, find, and manage events with Siri and Shortcuts; find them in Spotlight; use Control Center and Lock Screen controls.")
            }

            Section {
                Toggle("Show Event Title", isOn: Binding(
                    get: { showLiveActivityTitle },
                    set: { newValue in
                        showLiveActivityTitle = newValue
                        LiveActivityPrivacyPreference.setShowTitle(newValue)
                        Task { await LiveActivityReconciler.reconcile(context: modelContext, manager: liveActivityManager) }
                    }
                ))
                .accessibilityIdentifier("liveActivityShowTitleToggle")
                Toggle("Show Next Task", isOn: Binding(
                    get: { showLiveActivityNextTask },
                    set: { newValue in
                        showLiveActivityNextTask = newValue
                        LiveActivityPrivacyPreference.setShowNextTask(newValue)
                        Task { await LiveActivityReconciler.reconcile(context: modelContext, manager: liveActivityManager) }
                    }
                ))
                .accessibilityIdentifier("liveActivityShowNextTaskToggle")

                if let focusedLiveActivityEvent {
                    NavigationLink(destination: EventDetailView(event: focusedLiveActivityEvent)) {
                        Label(focusedLiveActivityEvent.title, systemImage: "bolt.fill")
                    }
                    .accessibilityIdentifier("openFocusedLiveActivityEventLink")
                    Button("Stop Live Activity", role: .destructive) {
                        let eventID = focusedLiveActivityEvent.id
                        isPerformingLiveActivityAction = true
                        Task {
                            await LiveActivityFocusCoordinator.stopFocus(eventID: eventID, manager: liveActivityManager)
                            self.focusedLiveActivityEvent = nil
                            isPerformingLiveActivityAction = false
                        }
                    }
                    .accessibilityIdentifier("settingsStopLiveActivityButton")
                    .disabled(isPerformingLiveActivityAction)
                } else {
                    Text("No event currently has an active Live Activity.")
                        .foregroundStyle(KueColor.secondaryText)
                        .accessibilityIdentifier("noFocusedLiveActivityLabel")
                }
            } header: {
                Text("Live Activity")
            } footer: {
                // docs/23 "I." — exact privacy matrix: title defaults on, next task defaults off.
                Text("Kue tracks one event's Live Activity at a time, shown on the Lock Screen and Dynamic Island. The next task's title stays hidden until you turn it on.")
            }

            Section {
                Button("Delete Everything", role: .destructive) {
                    isConfirmingDeleteEverything = true
                }
                .accessibilityIdentifier("deleteEverythingButton")
            } header: {
                Text("Privacy")
            } footer: {
                // docs/11-privacy-and-offline.md "Privacy principles" — required, not optional.
                Text("Deletes every event and resets all settings. This can't be undone.")
            }
        }
        .navigationTitle("Settings")
        .task {
            preference = UserPreferenceStore.current(context: modelContext)
            authorizationStatus = await scheduler.authorizationStatus()
            // Requirement 6: a pure state *read*, never a request — `authorizationState()`
            // itself never prompts.
            calendarAuthorizationState = calendarProvider.authorizationState()
            if let focusedID = await liveActivityManager.focusedEventID() {
                focusedLiveActivityEvent = (try? modelContext.fetch(
                    FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == focusedID })
                ))?.first
            }
        }
        .confirmationDialog(
            "Delete all events and reset settings? This can't be undone.",
            isPresented: $isConfirmingDeleteEverything,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                PrivacyActions.deleteEverything(context: modelContext, scheduler: scheduler, widgetReloader: widgetReloader)
                preference = UserPreferenceStore.current(context: modelContext)
                haptics.play(.destructiveConfirmed)
            }
            .accessibilityIdentifier("confirmDeleteEverythingButton")
        }
    }

    @ViewBuilder
    private var permissionStatusRow: some View {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "bell.badge")
                .accessibilityIdentifier("notificationStatusOn")
        case .denied:
            Label("Notifications are off", systemImage: "bell.slash")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("notificationStatusDenied")
        case .notDetermined:
            Label("Not yet requested", systemImage: "bell")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("notificationStatusNotDetermined")
        @unknown default:
            Label("Notifications are off", systemImage: "bell.slash")
                .foregroundStyle(KueColor.secondaryText)
        }
    }

    /// Requirement 4 — every authorization state gets its own row, distinctly labeled and
    /// accessibility-identified so a UI test can assert exactly which one is showing.
    @ViewBuilder
    private var calendarStatusRow: some View {
        switch calendarAuthorizationState {
        case .fullAccess:
            Label("Calendar access is on", systemImage: "calendar.badge.checkmark")
                .accessibilityIdentifier("calendarStatusFullAccess")
        case .writeOnly:
            Label("Calendar access is on (add-only)", systemImage: "calendar.badge.plus")
                .accessibilityIdentifier("calendarStatusWriteOnly")
        case .denied:
            Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("calendarStatusDenied")
        case .restricted:
            Label("Calendar access is restricted", systemImage: "lock")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("calendarStatusRestricted")
        case .notDetermined:
            Label("Not yet requested", systemImage: "calendar")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("calendarStatusNotDetermined")
        case .unavailable:
            Label("Calendar access is unavailable", systemImage: "calendar.badge.exclamationmark")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("calendarStatusUnavailable")
        case .unknown:
            Label("Calendar access is unavailable", systemImage: "calendar.badge.exclamationmark")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("calendarStatusUnknown")
        }
    }

    private func requestCalendarAccess() async {
        isRequestingCalendarAccess = true
        calendarAuthorizationState = await calendarProvider.requestAccess()
        isRequestingCalendarAccess = false
    }

    private func intensityDescription(_ intensity: NotificationIntensity) -> String {
        switch intensity {
        case .minimal: return "Only today/urgent reminders fire."
        case .standard: return "Preparation, tomorrow, and today/urgent reminders fire."
        case .all: return "Every reminder fires, including one per task."
        }
    }

    private func reschedule(intensity: NotificationIntensity) async {
        await NotificationEngine.reschedule(context: modelContext, intensity: intensity, scheduler: scheduler)
    }
}

#Preview("Settings — Light") {
    NavigationStack {
        SettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
}

#Preview("Settings — Dark") {
    NavigationStack {
        SettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
    .preferredColorScheme(.dark)
}

#Preview("Settings — Large Dynamic Type") {
    NavigationStack {
        SettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
