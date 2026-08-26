//
//  SettingsView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Settings": AI on/off, notification intensity, appearance,
//  privacy controls arrive alongside the phases that back them. Phase 8 (M7) adds the
//  notifications section — docs/08-notifications.md "User control over intensity" and
//  docs/13-error-handling.md "Notification permission denied" (persistent, non-nagging
//  indicator, not a repeated prompt). AI on/off, appearance, and privacy remain unbuilt.
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var preference: UserPreference?
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Injected for tests (requirement 10) — the live default is what KueApp effectively
    /// uses everywhere else.
    var scheduler: NotificationScheduling = SystemNotificationScheduler.shared

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
            }
        }
        .navigationTitle("Settings")
        .task {
            preference = UserPreferenceStore.current(context: modelContext)
            authorizationStatus = await scheduler.authorizationStatus()
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
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notificationStatusDenied")
        case .notDetermined:
            Label("Not yet requested", systemImage: "bell")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notificationStatusNotDetermined")
        @unknown default:
            Label("Notifications are off", systemImage: "bell.slash")
                .foregroundStyle(.secondary)
        }
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

#Preview {
    NavigationStack {
        SettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
}
