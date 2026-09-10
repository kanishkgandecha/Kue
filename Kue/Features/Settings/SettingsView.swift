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
import UIKit

struct SettingsView: View {
    var showOnboarding: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.calendarProvider) private var calendarProvider
    // Kue 2.0 Phase 7 — requirement 32/34: the one destructive confirmation this screen has.
    @Environment(\.kueHaptics) private var haptics
    // Kue 2.0 Phase 9 — same DI seam Event Detail's Focus section reads.
    @Environment(\.liveActivityManager) private var liveActivityManager
    @State private var preference: UserPreference?
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    // Kue 2.0 Phase 10.1 — docs/25 "H.": the configurable pre-event reminder duration.
    // App Group `UserDefaults`-backed (`ReminderPreference`), not `UserPreference`/SwiftData —
    // same "avoid a schema change for a simple global setting" precedent
    // `LiveActivityPrivacyPreference`/`SpotlightIndexingPreference` already establish below.
    @State private var reminderMinutes: Int? = ReminderPreference.current.preEventMinutes
    @State private var isConfirmingDeleteEverything = false
    // Kue 2.0 Phase 4 — Calendar section (docs/18-calendar-integration.md "Settings").
    @State private var calendarAuthorizationState: CalendarAuthorizationState = .notDetermined
    @State private var isRequestingCalendarAccess = false

    // MARK: Kue 2.0 Phase 9 — Live Activity focus management (docs/23 "F./I.")
    @State private var focusedLiveActivityEvent: KueEvent?
    @State private var isPerformingLiveActivityAction = false
    @State private var showLiveActivityTitle = LiveActivityPrivacyPreference.current.showTitle
    @State private var showLiveActivityNextTask = LiveActivityPrivacyPreference.current.showNextTask

    // MARK: Kue 2.0 Phase 11 — iCloud Sync (docs/26 "K./G.")
    @State private var isSyncEnabled = SyncPreference.current.isEnabled
    @State private var isPerformingSyncNow = false
    @State private var syncPersistentState = SyncCoordinator.shared.stateStore.load()
    @State private var isReviewingAccountChange = false

    // MARK: Kue 2.0 Phase 12 — Backup & Restore (docs/28)
    @State private var isExportingBackup = false
    @State private var backupExportDocument: BackupFileDocument?
    @State private var isImportingBackup = false
    @State private var pendingRestorePayload: BackupPayload?
    @State private var pendingRestoreEnvelope: BackupEnvelope?
    @State private var isConfirmingRestore = false
    @State private var backupAlertMessage: String?

    /// Injected for tests (requirement 10) — the live default is what KueApp effectively
    /// uses everywhere else.
    var scheduler: NotificationScheduling = SystemNotificationScheduler.shared
    var widgetReloader: WidgetReloading = SystemWidgetReloader.shared

    init(
        showOnboarding: (() -> Void)? = nil,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        widgetReloader: WidgetReloading = SystemWidgetReloader.shared
    ) {
        self.scheduler = scheduler
        self.widgetReloader = widgetReloader
        self.showOnboarding = showOnboarding
    }

    var body: some View {
        Form {
            Section {
                permissionStatusRow
                if authorizationStatus == .denied {
                    Button("Open Notification Settings") { openSystemSettings() }
                        .accessibilityIdentifier("openNotificationSettingsButton")
                }
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
                    Picker("Event Reminder", selection: Binding(
                        get: { reminderMinutes },
                        set: { newValue in
                            reminderMinutes = newValue
                            ReminderPreference.setPreEventMinutes(newValue)
                            Task { await reschedule(intensity: preference.notificationIntensity) }
                        }
                    )) {
                        ForEach(ReminderPreference.availableOptions, id: \.self) { minutes in
                            Text(ReminderPreference.displayName(forMinutes: minutes)).tag(minutes)
                        }
                    }
                    .accessibilityIdentifier("reminderDurationPicker")
                } footer: {
                    // docs/25 "H.": a timed reminder before the event starts, separate from
                    // the always-on "starting now" and "how did it go" notifications.
                    Text("A reminder before each timed event starts, in addition to the notification when it actually begins.")
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
                } else if calendarAuthorizationState == .denied {
                    Button("Open Calendar Settings") { openSystemSettings() }
                        .accessibilityIdentifier("openCalendarSettingsButton")
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

            // Post-Phase-12 fix — app-managed Lock Screen widget event selection, independent
            // of WidgetKit's own long-press/Edit Widget flow.
            Section {
                NavigationLink {
                    LockScreenEventSelectionView()
                } label: {
                    LabeledContent("Lock Screen Event") {
                        if let id = LockScreenEventSelection.current, let event = try? modelContext.fetch(
                            FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })
                        ).first {
                            Text(event.title)
                        } else if LockScreenEventSelection.current != nil {
                            Text("Unavailable")
                        } else {
                            Text("None")
                        }
                    }
                }
                .accessibilityIdentifier("lockScreenEventSettingsLink")
            } header: {
                Text("Widgets")
            } footer: {
                Text("Choose which event Kue's Lock Screen widgets show. This applies to every placed Lock Screen widget — they can't each track a different event.")
            }

            Section {
                #if KUE_PERSONAL_BUILD
                // Kue 2.0 Phase 12 — docs/27: this build's entitlements structurally exclude
                // CloudKit (the free Apple Developer Personal Team can't provision it), so
                // there's no working toggle to show — a disabled one that silently does
                // nothing on tap would be dishonest. `SyncPreference` is also forced off at
                // the source (see SyncPreference.swift), so this copy and that behavior can
                // never drift apart.
                Label("iCloud Sync Requires Apple Developer Program", systemImage: "icloud.slash")
                    .foregroundStyle(KueColor.secondaryText)
                    .accessibilityIdentifier("iCloudSyncUnavailableLabel")
                #else
                Toggle("iCloud Sync", isOn: Binding(
                    get: { isSyncEnabled },
                    set: { newValue in
                        isSyncEnabled = newValue
                        SyncPreference.setEnabled(newValue)
                        if newValue {
                            Task {
                                isPerformingSyncNow = true
                                await SyncCoordinator.shared.sync(context: modelContext)
                                syncPersistentState = SyncCoordinator.shared.stateStore.load()
                                isPerformingSyncNow = false
                            }
                        } else {
                            // docs/26 "K.": "Disabling sync stops cloud transfers, retains
                            // local data, does not delete CloudKit content, does not delete
                            // local content." No mutation here beyond the preference flip —
                            // `SyncCoordinator.sync` itself already checks `SyncPreference`
                            // first thing and no-ops entirely while it's off.
                            SyncCoordinator.shared.pauseForSignOut()
                        }
                    }
                ))
                .accessibilityIdentifier("iCloudSyncToggle")

                if isSyncEnabled {
                    syncStatusRow
                    if let lastSync = syncPersistentState.lastSuccessfulSyncAt {
                        LabeledContent("Last Synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityIdentifier("lastSyncedLabel")
                    }
                    let pendingCount = SyncOutbox.pendingChangeCount(store: SyncCoordinator.shared.stateStore)
                    if pendingCount > 0 {
                        LabeledContent("Waiting to Upload", value: "\(pendingCount)")
                            .accessibilityIdentifier("pendingSyncCountLabel")
                    }
                    Button {
                        Task {
                            isPerformingSyncNow = true
                            await SyncCoordinator.shared.sync(context: modelContext)
                            syncPersistentState = SyncCoordinator.shared.stateStore.load()
                            isPerformingSyncNow = false
                        }
                    } label: {
                        if isPerformingSyncNow {
                            ProgressView()
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .accessibilityIdentifier("syncNowButton")
                    .disabled(isPerformingSyncNow)

                    if SyncCoordinator.shared.status == .accountChanged {
                        Button("Review Account Change") { isReviewingAccountChange = true }
                            .accessibilityIdentifier("reviewAccountChangeButton")
                    }
                }
                #endif
            } header: {
                Text("iCloud Sync")
            } footer: {
                #if KUE_PERSONAL_BUILD
                Text("This build was installed directly from source without a paid Apple Developer Program membership, which iCloud sync requires. Your events stay on this device only. Back up from Settings → Backup & Restore before reinstalling.")
                #else
                // docs/26 "K.": privacy explanation — never claims immediacy.
                Text("Syncs your events privately through your own iCloud account — Kue has no server of its own and no one else can see your data. Sync timing depends on network and iCloud availability, not guaranteed immediate.")
                #endif
            }

            Section {
                Button("Export Backup") {
                    do {
                        let data = try BackupCoder.exportData(context: modelContext)
                        backupExportDocument = BackupFileDocument(data: data)
                        isExportingBackup = true
                    } catch {
                        backupAlertMessage = "Couldn't create a backup: \(error.localizedDescription)"
                    }
                }
                .accessibilityIdentifier("exportBackupButton")

                Button("Restore from Backup") {
                    isImportingBackup = true
                }
                .accessibilityIdentifier("restoreBackupButton")
            } header: {
                Text("Backup & Restore")
            } footer: {
                // docs/28 — honest about what restore does: merges by matching event, never a
                // silent full replace (see BackupRestoreService.swift for why).
                Text("Export saves everything Kue knows about — events, tasks, templates, and settings — to a file you control. Restoring merges a backup into what's already on this device; it never deletes anything.")
            }

            Section {
                if let showOnboarding {
                    Button("Show Welcome Guide") { showOnboarding() }
                        .accessibilityIdentifier("showOnboardingButton")
                }

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

            #if DEBUG
            // Kue 3.0 Phase 2 (docs/30 "Debug validation gallery") — compiled out of every
            // Release build entirely (not merely hidden), since `#if DEBUG` excludes both the
            // section below and `LiveActivityDebugGalleryView` itself from that configuration.
            Section {
                NavigationLink("Live Activity Gallery") {
                    LiveActivityDebugGalleryView()
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug builds only. Lets you preview every Live Activity/Dynamic Island fixture on this device without touching real events.")
            }
            #endif
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
        .confirmationDialog(
            "Local Kue data currently belongs to a different iCloud account. Keep your data on this device and start syncing fresh with the new account?",
            isPresented: $isReviewingAccountChange,
            titleVisibility: .visible
        ) {
            // docs/26 "G.": the only offered path — the previous account's queued/engine
            // state is quarantined, this device's local data is fully preserved, and the new
            // account starts as a fresh initial-sync target. Never a silent merge.
            Button("Keep My Data & Start Fresh") {
                Task {
                    await SyncCoordinator.shared.resolveAccountChange(keepLocalAndStartFresh: true)
                    await SyncCoordinator.shared.sync(context: modelContext)
                    syncPersistentState = SyncCoordinator.shared.stateStore.load()
                }
            }
            .accessibilityIdentifier("confirmAccountChangeButton")
        }
        // MARK: Kue 2.0 Phase 12 — Backup & Restore (docs/28)
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupExportDocument,
            contentType: .kueBackup,
            defaultFilename: "Kue Backup \(Date().formatted(date: .numeric, time: .omitted))"
        ) { result in
            if case .failure(let error) = result {
                backupAlertMessage = "Couldn't save the backup: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.kueBackup]) { result in
            switch result {
            case .failure(let error):
                backupAlertMessage = "Couldn't open that file: \(error.localizedDescription)"
            case .success(let url):
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let (envelope, payload) = try BackupCoder.decodeAndValidate(data)
                    pendingRestoreEnvelope = envelope
                    pendingRestorePayload = payload
                    isConfirmingRestore = true
                } catch let error as BackupError {
                    backupAlertMessage = restoreErrorMessage(for: error)
                } catch {
                    backupAlertMessage = "Couldn't read that backup file."
                }
            }
        }
        .confirmationDialog(
            restoreConfirmationTitle,
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                guard let payload = pendingRestorePayload else { return }
                Task {
                    do {
                        let summary = try await BackupRestoreService.restore(payload: payload, context: modelContext)
                        let eventCount = summary.eventsInserted + summary.eventsUpdated
                        backupAlertMessage = "Restored \(eventCount) event\(eventCount == 1 ? "" : "s")."
                        preference = UserPreferenceStore.current(context: modelContext)
                    } catch {
                        backupAlertMessage = "Restore failed: \(error.localizedDescription)"
                    }
                    pendingRestorePayload = nil
                    pendingRestoreEnvelope = nil
                }
            }
            .accessibilityIdentifier("confirmRestoreBackupButton")
            Button("Cancel", role: .cancel) {
                pendingRestorePayload = nil
                pendingRestoreEnvelope = nil
            }
        }
        .alert(
            "Backup",
            isPresented: Binding(get: { backupAlertMessage != nil }, set: { if !$0 { backupAlertMessage = nil } })
        ) {
            Button("OK") { backupAlertMessage = nil }
        } message: {
            Text(backupAlertMessage ?? "")
        }
    }

    // MARK: Kue 2.0 Phase 12 — Backup & Restore helpers (docs/28)

    private var restoreConfirmationTitle: String {
        guard let payload = pendingRestorePayload, let envelope = pendingRestoreEnvelope else {
            return "Restore this backup?"
        }
        let date = envelope.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "Restore \(payload.events.count) event\(payload.events.count == 1 ? "" : "s") from a backup made \(date)? This merges into what's already on this device — nothing existing is deleted."
    }

    private func restoreErrorMessage(for error: BackupError) -> String {
        switch error {
        case .notABackupFile:
            return "That file isn't a Kue backup."
        case .checksumMismatch:
            return "That backup file is corrupted or was edited outside Kue."
        case .unsupportedFutureFormatVersion:
            return "That backup was made by a newer version of Kue. Update Kue and try again."
        case .malformedPayload:
            return "That backup file is corrupted."
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        let status = SyncCoordinator.shared.status
        Label(status.displayText, systemImage: syncStatusSymbol(status))
            .foregroundStyle(status == .accountChanged || status.isErrorLike ? KueColor.warning : KueColor.secondaryText)
            .accessibilityIdentifier("syncStatusLabel")
    }

    private func syncStatusSymbol(_ status: SyncStatus) -> String {
        switch status {
        case .off: return "icloud.slash"
        case .checkingAccount, .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .upToDate: return "checkmark.icloud"
        case .waitingForNetwork: return "wifi.slash"
        case .waitingForSignIn: return "person.crop.circle.badge.exclamationmark"
        case .paused: return "pause.circle"
        case .changesWaitingToUpload: return "icloud.and.arrow.up"
        case .conflictNeedsReview: return "exclamationmark.icloud"
        case .temporarilyUnavailable: return "icloud.slash"
        case .syncError: return "exclamationmark.triangle"
        case .accountChanged: return "person.crop.circle.badge.exclamationmark"
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

    private func openSystemSettings() {
        // Kue 2.0 Phase 12 — docs/28: `UIApplication.openSettingsURLString` is Apple's own
        // documented constant for "this app's page in Settings.app," not a hardcoded literal —
        // the exact scheme string isn't part of any public contract and has changed across iOS
        // versions before.
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func intensityDescription(_ intensity: NotificationIntensity) -> String {
        // Kue 2.0 Phase 10.1 — docs/25 "J.": event-start and "how did it go" are essentials
        // that fire at every intensity, not just "today/urgent" — this copy has to say so
        // honestly rather than imply Minimal silences them.
        switch intensity {
        case .minimal: return "Only the essentials fire: today/urgent, when an event starts, and its outcome follow-up."
        case .standard: return "Preparation, tomorrow, and today/urgent reminders fire, plus the essentials."
        case .all: return "Every reminder fires, including one per task."
        }
    }

    private func reschedule(intensity: NotificationIntensity) async {
        await NotificationEngine.reschedule(context: modelContext, intensity: intensity, scheduler: scheduler, reminderPreference: ReminderPreference.current)
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
