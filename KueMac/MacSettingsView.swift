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

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var calendarAuthorizationState: CalendarAuthorizationState = .notDetermined
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupExportDocument: BackupFileDocument?
    @State private var pendingRestoreEnvelope: BackupEnvelope?
    @State private var pendingRestorePayload: BackupPayload?
    @State private var isConfirmingRestore = false
    @State private var isConfirmingDeleteEverything = false
    @State private var backupAlertMessage: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
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
                Text("Notifications")
            } footer: {
                Text("Notification behavior mirrors the iPhone app — a redesigned Notification Studio is planned for a later Kue 3.0 phase, not this one.")
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
