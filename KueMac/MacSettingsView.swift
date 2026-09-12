//
//  MacSettingsView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — native macOS Settings scene content (`Settings { }` in `KueMacApp`, not
//  a sidebar destination — matches native Mac convention, reached via Kue ▸ Settings…/⌘,).
//  Backup reuses `BackupCoder`/`BackupRestoreService`/`BackupFileDocument` (Shared/) verbatim
//  — the exact `.kuebackup` format and merge-by-UUID restore policy the iPhone app uses, so a
//  file exported from either platform opens on the other. No Notification Studio redesign
//  here (Phase 3 work) — just a truthful read of the existing authorization state.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications
#if os(macOS)
import AppKit
#endif

struct MacSettingsView: View {
    var appState: MacAppState

    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendarProvider) private var calendarProvider
    // Kue 3.0 Phase 6 — docs/34 "Refresh behavior."
    @Environment(AccountCoordinator.self) private var accountCoordinator

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationPreferences = NotificationGlobalPreferences.current
    @State private var calendarAuthorizationState: CalendarAuthorizationState = .notDetermined
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupExportDocument: BackupFileDocument?
    @State private var pendingRestoreEnvelope: BackupEnvelope?
    @State private var pendingRestorePayload: BackupPayload?
    @State private var isConfirmingRestore = false
    @State private var isConfirmingDeleteEverything = false
    @State private var backupAlertMessage: String?

    /// Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification Studio parity".
    @State private var isShowingApplyToExistingSheet = false
    // Kue 3.0 Phase 7 — docs/35 "Notification Control Center."
    @State private var eventTypeBeingEdited: EventType?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            MacAccountView().tabItem { Label("Account", systemImage: "person.crop.circle") }
            MacInsightsView().tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
            MacSyncView().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
            notificationsTab.tabItem { Label("Notifications", systemImage: "bell") }
            backupTab.tabItem { Label("Backup", systemImage: "arrow.down.doc") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .task {
            notificationStatus = await SystemNotificationScheduler.shared.authorizationStatus()
            // Requirement 6, carried over from iOS: a pure state *read*, never a request.
            calendarAuthorizationState = calendarProvider.authorizationState()
        }
        .fileExporter(
            isPresented: $isExportingBackup, document: backupExportDocument, contentType: .kueBackup,
            defaultFilename: "Kue Backup \(Date().formatted(date: .numeric, time: .omitted))"
        ) { result in
            if case .failure(let error) = result {
                backupAlertMessage = "Couldn't save the backup: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.kueBackup]) { result in
            handleImportResult(result)
        }
        .confirmationDialog(restoreConfirmationTitle, isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("Restore") { performRestore() }
            Button("Cancel", role: .cancel) { clearPendingRestore() }
        }
        .confirmationDialog(
            "Delete all events and reset settings? This can't be undone.",
            isPresented: $isConfirmingDeleteEverything, titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                PrivacyActions.deleteEverything(context: modelContext)
            }
        }
        .alert("Backup", isPresented: Binding(get: { backupAlertMessage != nil }, set: { if !$0 { backupAlertMessage = nil } })) {
            Button("OK") { backupAlertMessage = nil }
        } message: {
            Text(backupAlertMessage ?? "")
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent("Status", value: notificationStatusText)
                if notificationStatus == .denied {
                    Button("Open System Settings") { openNotificationSettings() }
                }
            } header: {
                Text("Notification Permission")
            } footer: {
                Text("The full Notification Studio — global defaults, quiet hours, and per-device delivery — lives in the Notifications tab.")
            }

            Section {
                LabeledContent("Status", value: calendarStatusText)
                if let explanation = calendarAuthorizationState.explanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                switch calendarAuthorizationState {
                case .notDetermined:
                    Button("Allow Calendar Access") {
                        Task { calendarAuthorizationState = await calendarProvider.requestAccess() }
                    }
                case .denied, .writeOnly:
                    Button("Open System Settings") { openCalendarSettings() }
                default:
                    EmptyView()
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Kue can import Apple Calendar events into editable drafts and add or update events you explicitly export — nothing happens automatically. Import isn't built into Kue for Mac yet; export/update/unlink from an event's own Detail view is.")
            }

            Section {
                LabeledContent("Storage") {
                    Text(ModelContainerFactory.storeURL().deletingLastPathComponent().path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Local Data")
            } footer: {
                #if KUE_PERSONAL_BUILD
                Text("This Personal build stores everything only on this Mac — there is no iCloud/CloudKit capability and no automatic sync with your iPhone. Use Backup to move data between devices.")
                #else
                Text("Kue for Mac stores everything only on this Mac in Phase 1 — there is no automatic sync with your iPhone yet. Use Backup to move data between devices.")
                #endif
            }

            Section {
                Button("Delete Everything", role: .destructive) { isConfirmingDeleteEverything = true }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Deletes every event and resets all settings on this Mac. This can't be undone.")
            }

            Section {
                Button("Show Welcome Guide") { appState.pendingCommand = .showOnboarding }
            }
        }
    }

    // MARK: - Notifications (Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification
    // Studio parity"). Same `NotificationGlobalPreferences` (App Group `UserDefaults`,
    // per-device by construction) and bindings pattern as iPhone's own
    // `NotificationStudioSettingsView` — a native macOS `Form`/`.formStyle(.grouped)` tab here,
    // not that iOS view embedded.

    private var notificationsTab: some View {
        Form {
            Section {
                LabeledContent("Status", value: notificationStatusText)
                if notificationStatus == .denied {
                    Button("Open System Settings") { openNotificationSettings() }
                }
                Toggle("Kue Notifications", isOn: notificationBinding(\.masterEnabled))
                    .accessibilityIdentifier("macMasterNotificationsToggle")
                Toggle("Deliver on This Mac", isOn: notificationBinding(\.deliverOnThisDevice))
                    .accessibilityIdentifier("macDeliverOnThisDeviceToggle")
            } footer: {
                Text("\"Deliver on This Mac\" only affects this computer — it is not synced with your iPhone. If you turn it on for more than one of your devices, you may see the same reminder on each of them.")
            }

            Section("Default Event Rules") {
                Picker("Before Event Start", selection: notificationBinding(\.defaultPreEventMinutes)) {
                    ForEach(ReminderPreference.availableOptions, id: \.self) { minutes in
                        Text(ReminderPreference.displayName(forMinutes: minutes)).tag(minutes)
                    }
                }
                Toggle("Outcome Follow-Up (\"How did it go?\")", isOn: notificationBinding(\.defaultOutcomeFollowUpEnabled))
            }

            Section("Default Task Rules") {
                Picker("Before Task Due", selection: notificationBinding(\.defaultTaskReminderMinutesBeforeDue)) {
                    Text("At due time").tag(Int?.none)
                    Text("15 minutes before").tag(Int?.some(15))
                    Text("30 minutes before").tag(Int?.some(30))
                    Text("1 hour before").tag(Int?.some(60))
                }
            }

            Section {
                DatePicker("Preferred Time", selection: allDayPreferredTimeBinding, displayedComponents: .hourAndMinute)
            } header: {
                Text("All-Day Events")
            } footer: {
                Text("All-day events have no clock time of their own, so reminders that reference \"event start\" use this time instead of midnight.")
            }

            // Kue 3.0 Phase 7 — docs/35 "Notification Control Center." Same Event Type scope
            // and Daily/Weekly Summary configuration as iPhone — shared model, shared engine,
            // native `Form` presentation. A `.sheet`, not `NavigationLink` — this tab has no
            // navigation stack of its own to push into (same reason `MacAccountView`'s own
            // drill-in content is always a sheet, never a push).
            Section {
                ForEach(EventType.allCases, id: \.self) { eventType in
                    Button(eventType.displayName) {
                        eventTypeBeingEdited = eventType
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Event Type Overrides")
            } footer: {
                Text("Rules here apply to every event of that type, unless a specific event overrides them.")
            }

            macDailySummarySection
            macWeeklySummarySection

            quietHoursSection

            Section("Sound & Presentation") {
                Picker("Sound", selection: notificationBinding(\.soundPreference)) {
                    Text("Default").tag(NotificationSoundOption.defaultSound)
                    Text("Silent").tag(NotificationSoundOption.silent)
                }
                Toggle("Badge App Icon", isOn: notificationBinding(\.badgeEnabled))
                Toggle("Group by Event", isOn: notificationBinding(\.groupNotificationsByEvent))
                Toggle("Time-Sensitive", isOn: notificationBinding(\.timeSensitiveEnabled))
                Toggle("Reduce on Weekends", isOn: Binding(
                    get: { !notificationPreferences.nonEssentialNotificationsOnWeekends },
                    set: { notificationPreferences.nonEssentialNotificationsOnWeekends = !$0; saveNotificationPreferences() }
                ))
            }

            Section {
                Picker("Notification Previews", selection: notificationBinding(\.previewPrivacy)) {
                    Text("Full").tag(NotificationPreviewPrivacy.full)
                    Text("Event Only").tag(NotificationPreviewPrivacy.eventOnly)
                    Text("Private").tag(NotificationPreviewPrivacy.private)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text(previewPrivacyExplanation)
            }

            Section {
                Button("Apply New Defaults to Existing Events…") {
                    isShowingApplyToExistingSheet = true
                }
                .accessibilityIdentifier("macApplyDefaultsToExistingEventsButton")
            } footer: {
                Text("Global defaults above only affect events you create from now on. Use this to review and optionally apply them to events you already have.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingApplyToExistingSheet) {
            MacApplyDefaultsToExistingEventsView(preferences: notificationPreferences)
        }
        .sheet(item: $eventTypeBeingEdited) { eventType in
            NavigationStack { MacEventTypeNotificationRulesView(eventType: eventType) }
        }
    }

    // MARK: - Daily / Weekly Summary (Kue 3.0 Phase 7 — docs/35)

    private var macDailySummarySection: some View {
        Section {
            Toggle("Daily Summary", isOn: Binding(
                get: { notificationPreferences.effectiveDailySummary.isEnabled },
                set: { var s = notificationPreferences.effectiveDailySummary; s.isEnabled = $0; notificationPreferences.dailySummary = s; saveNotificationPreferences() }
            ))
            .accessibilityIdentifier("macDailySummaryToggle")
            if notificationPreferences.effectiveDailySummary.isEnabled {
                DatePicker("Delivery Time", selection: macMinuteBinding(
                    get: { notificationPreferences.effectiveDailySummary.deliveryMinuteOfDay },
                    set: { var s = notificationPreferences.effectiveDailySummary; s.deliveryMinuteOfDay = $0; notificationPreferences.dailySummary = s }
                ), displayedComponents: .hourAndMinute)
                Picker("Covers", selection: Binding(
                    get: { notificationPreferences.effectiveDailySummary.scope },
                    set: { var s = notificationPreferences.effectiveDailySummary; s.scope = $0; notificationPreferences.dailySummary = s; saveNotificationPreferences() }
                )) {
                    Text("Today").tag(DailySummaryScope.today)
                    Text("Tomorrow").tag(DailySummaryScope.tomorrow)
                }
            }
        } header: {
            Text("Daily Summary")
        } footer: {
            Text("A single reminder with just a count — never event titles or notes.")
        }
    }

    private var macWeeklySummarySection: some View {
        Section {
            Toggle("Weekly Summary", isOn: Binding(
                get: { notificationPreferences.effectiveWeeklySummary.isEnabled },
                set: { var s = notificationPreferences.effectiveWeeklySummary; s.isEnabled = $0; notificationPreferences.weeklySummary = s; saveNotificationPreferences() }
            ))
            .accessibilityIdentifier("macWeeklySummaryToggle")
            if notificationPreferences.effectiveWeeklySummary.isEnabled {
                Picker("Day", selection: Binding(
                    get: { notificationPreferences.effectiveWeeklySummary.weekday },
                    set: { var s = notificationPreferences.effectiveWeeklySummary; s.weekday = $0; notificationPreferences.weeklySummary = s; saveNotificationPreferences() }
                )) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }
                DatePicker("Delivery Time", selection: macMinuteBinding(
                    get: { notificationPreferences.effectiveWeeklySummary.deliveryMinuteOfDay },
                    set: { var s = notificationPreferences.effectiveWeeklySummary; s.deliveryMinuteOfDay = $0; notificationPreferences.weeklySummary = s }
                ), displayedComponents: .hourAndMinute)
                Stepper("Next \(notificationPreferences.effectiveWeeklySummary.upcomingWindowDays) days", value: Binding(
                    get: { notificationPreferences.effectiveWeeklySummary.upcomingWindowDays },
                    set: { var s = notificationPreferences.effectiveWeeklySummary; s.upcomingWindowDays = $0; notificationPreferences.weeklySummary = s; saveNotificationPreferences() }
                ), in: 1...30)
            }
        } header: {
            Text("Weekly Summary")
        } footer: {
            Text("A single reminder with just a count of what's coming up — never event titles or notes.")
        }
    }

    private func macMinuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: get() / 60, minute: get() % 60, second: 0, of: .now) ?? .now },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                set((components.hour ?? 0) * 60 + (components.minute ?? 0))
                saveNotificationPreferences()
            }
        )
    }

    private var quietHoursSection: some View {
        Section {
            Toggle("Quiet Hours", isOn: notificationBinding(\.quietHours.isEnabled))
                .accessibilityIdentifier("macQuietHoursToggle")
            if notificationPreferences.quietHours.isEnabled {
                DatePicker("Starts", selection: quietHoursTimeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: quietHoursTimeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                Toggle("Allow Event-Start Notifications", isOn: notificationBinding(\.quietHours.allowEventStartThrough))
                Toggle("Allow Time-Sensitive Notifications", isOn: notificationBinding(\.quietHours.allowTimeSensitiveThrough))
                weekdayPicker
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            Text("A reminder due during quiet hours is delivered right when quiet hours end, not silently dropped.")
        }
    }

    private var weekdayPicker: some View {
        let symbols = Calendar.current.weekdaySymbols
        return ForEach(1...7, id: \.self) { weekday in
            Toggle(symbols[weekday - 1], isOn: Binding(
                get: { notificationPreferences.quietHours.enabledWeekdays.contains(weekday) },
                set: { isOn in
                    if isOn { notificationPreferences.quietHours.enabledWeekdays.insert(weekday) }
                    else { notificationPreferences.quietHours.enabledWeekdays.remove(weekday) }
                    saveNotificationPreferences()
                }
            ))
        }
    }

    private func quietHoursTimeBinding(_ keyPath: WritableKeyPath<NotificationQuietHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = notificationPreferences.quietHours[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                notificationPreferences.quietHours[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                saveNotificationPreferences()
            }
        )
    }

    private var allDayPreferredTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minute = notificationPreferences.allDayPreferredMinuteOfDay
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                notificationPreferences.allDayPreferredMinuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                saveNotificationPreferences()
            }
        )
    }

    private var previewPrivacyExplanation: String {
        switch notificationPreferences.previewPrivacy {
        case .full: return "Notifications show the real event and task names."
        case .eventOnly: return "Notifications show the event name; task-specific reminders use generic text."
        case .private: return "Notifications never show event or task names — just \"You have a Kue reminder.\""
        }
    }

    private func notificationBinding<Value>(_ keyPath: WritableKeyPath<NotificationGlobalPreferences, Value>) -> Binding<Value> {
        Binding(get: { notificationPreferences[keyPath: keyPath] }, set: { notificationPreferences[keyPath: keyPath] = $0; saveNotificationPreferences() })
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not yet requested"
        @unknown default: return "Unknown"
        }
    }

    private func openNotificationSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// Kue 3.0 Phase 3 — docs/31. Mirrors `NotificationStudioSettingsView.save()`'s own
    /// save-then-reschedule sequence exactly, so a global preference changed on the Mac takes
    /// effect on the Mac's own pending schedule immediately, the same guarantee iPhone already has.
    private func saveNotificationPreferences() {
        NotificationGlobalPreferences.save(notificationPreferences)
        Task {
            await NotificationEngine.reschedule(
                context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity,
                scheduler: SystemNotificationScheduler.shared, globalPreferences: notificationPreferences
            )
        }
    }

    // MARK: - Calendar (Kue 3.0 Phase 1 cleanup — see docs/29 "Calendar")

    private var calendarStatusText: String {
        switch calendarAuthorizationState {
        case .fullAccess: return "Allowed"
        case .writeOnly: return "Allowed (add-only)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet requested"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    private func openCalendarSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Backup

    private var backupTab: some View {
        Form {
            Section {
                Button("Export Backup…") {
                    do {
                        let data = try BackupCoder.exportData(context: modelContext)
                        backupExportDocument = BackupFileDocument(data: data)
                        isExportingBackup = true
                    } catch {
                        backupAlertMessage = "Couldn't create a backup: \(error.localizedDescription)"
                    }
                }
                Button("Restore from Backup…") { isImportingBackup = true }
            } footer: {
                Text("Export saves everything Kue knows about — events, tasks, templates, and settings — to a .kuebackup file you control. A backup made on iPhone opens here, and one made here opens on iPhone. Restoring merges into what's already on this Mac; it never deletes anything.")
            }
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
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

    private var restoreConfirmationTitle: String {
        guard let payload = pendingRestorePayload, let envelope = pendingRestoreEnvelope else {
            return "Restore this backup?"
        }
        let date = envelope.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "Restore \(payload.events.count) event\(payload.events.count == 1 ? "" : "s") from a backup made \(date)? This merges into what's already on this Mac — nothing existing is deleted."
    }

    private func performRestore() {
        guard let payload = pendingRestorePayload else { return }
        Task {
            do {
                let summary = try await BackupRestoreService.restore(payload: payload, context: modelContext)
                let count = summary.eventsInserted + summary.eventsUpdated
                backupAlertMessage = "Restored \(count) event\(count == 1 ? "" : "s")."
                // Kue 3.0 Phase 6 — docs/34 "Refresh behavior."
                let restoredEvents = (try? modelContext.fetch(FetchDescriptor<KueEvent>())) ?? []
                Task { await StatisticsCoordinator.shared.refreshCloudUpload(events: restoredEvents, account: accountCoordinator) }
            } catch {
                backupAlertMessage = "Restore failed: \(error.localizedDescription)"
            }
            clearPendingRestore()
        }
    }

    private func clearPendingRestore() {
        pendingRestorePayload = nil
        pendingRestoreEnvelope = nil
    }

    private func restoreErrorMessage(for error: BackupError) -> String {
        switch error {
        case .notABackupFile: return "That file isn't a Kue backup."
        case .checksumMismatch: return "That backup file is corrupted or was edited outside Kue."
        case .unsupportedFutureFormatVersion: return "That backup was made by a newer version of Kue. Update Kue and try again."
        case .malformedPayload: return "That backup file is corrupted."
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
            Text("Kue for Mac — Phase 1 Foundation. Core event management, shared with the iPhone app's own data model and services. See docs/29-kue-3-macos-foundation.md for what's implemented and what's still to come.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
