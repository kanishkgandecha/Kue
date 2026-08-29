//
//  OnboardingView.swift
//  Kue
//
//  Kue 2.0 Phase 12 — short, skippable education. It never asks for a system permission;
//  Calendar, notifications, microphone, speech, and Photos remain just-in-time requests at
//  the feature surface that needs them.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var isImportingBackup = false
    @State private var pendingRestore: BackupPayload?
    @State private var isConfirmingRestore = false
    @State private var message: String?

    private var pages: [(symbol: String, title: String, message: String)] {
        [
            ("calendar.badge.clock", "Your events, with a plan", "Add an exam, deadline, interview, trip, or anything important. Kue turns it into a clear timeline and preparation tasks."),
            ("bell.badge", "Reminders when they matter", "Kue asks for notifications only after you save an event. You stay in control of timing and intensity in Settings."),
            ("lock.shield", "Private by default", "Your data stays on your devices. Calendar, photos, microphone, and speech access are requested only when you choose those features."),
            ("externaldrive.badge.timemachine", "Keep a backup you control", backupPageMessage)
        ]
    }

    /// Kue 2.0 Phase 12 — docs/27/28: this build's own copy already tells the Personal-build
    /// story in Settings' iCloud Sync section (`SettingsView.swift`) — onboarding says the same
    /// thing at the one moment it matters most, before the user has anything to lose. A paid,
    /// CloudKit-capable build still benefits from an explicit backup, just for a different
    /// reason (device loss/reinstall, not "there is no sync at all").
    private var backupPageMessage: String {
        #if KUE_PERSONAL_BUILD
        return "This build has no iCloud sync — it's installed directly from source without a paid Apple Developer Program membership. Export a Kue backup now, and again before reinstalling or moving devices. Restoring merges a backup in without deleting anything already here."
        #else
        return "Export a Kue backup before reinstalling or moving devices. If you already have one, you can restore it now without deleting existing data."
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: pages[page].symbol)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(KueColor.accent)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(pages[page].title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(pages[page].message)
                        .font(.body)
                        .foregroundStyle(KueColor.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                Spacer()

                if page == pages.count - 1 {
                    Button("Restore from Backup") { isImportingBackup = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("onboardingRestoreBackupButton")
                }

                Button(page == pages.count - 1 ? "Start Using Kue" : "Continue") {
                    if page == pages.count - 1 {
                        finish()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboardingContinueButton")

                Text("Step \(page + 1) of \(pages.count)")
                    .font(.caption)
                    .foregroundStyle(KueColor.secondaryText)
                    .accessibilityLabel("Step \(page + 1) of \(pages.count)")
            }
            .padding(28)
            .navigationTitle("Welcome to Kue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { finish() }
                        .accessibilityIdentifier("onboardingSkipButton")
                }
            }
        }
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.kueBackup]) { result in
            do {
                let url = try result.get()
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let (_, payload) = try BackupCoder.decodeAndValidate(Data(contentsOf: url))
                pendingRestore = payload
                isConfirmingRestore = true
            } catch {
                message = "That backup couldn't be opened or validated."
            }
        }
        .confirmationDialog("Merge this backup into Kue? Nothing already here will be deleted.", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("Restore") {
                guard let payload = pendingRestore else { return }
                Task {
                    do {
                        let summary = try await BackupRestoreService.restore(payload: payload, context: modelContext)
                        message = "Restored \(summary.eventsInserted + summary.eventsUpdated) events."
                    } catch {
                        message = "Restore failed. Your existing data was not deleted."
                    }
                    pendingRestore = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func finish() {
        OnboardingPreference.markCompleted()
        dismiss()
    }
}
