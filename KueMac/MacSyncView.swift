//
//  MacSyncView.swift
//  KueMac
//
//  Kue 3.0 Phase 5 — docs/33 "Sync status and controls." The native Mac counterpart to
//  iPhone's Settings → Sync section — same underlying `SyncCoordinator`/`AccountCoordinator`,
//  same states, native `Form`/`.formStyle(.grouped)` controls instead of an embedded copy of
//  the iPhone layout (matching every other Mac Settings section's own precedent).
//

import SwiftUI
import SwiftData

struct MacSyncView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var isSyncEnabled = SyncPreference.current.isEnabled
    @State private var isPerformingSyncNow = false
    @State private var syncPersistentState = SyncCoordinator.shared.stateStore.load()
    @State private var isPresentingFirstSyncDecision = false
    @State private var isConfirmingDisableSync = false

    var body: some View {
        Form {
            switch accountCoordinator.state {
            case .unavailable:
                Label("Sync Isn't Set Up in This Build", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            case .signedOut, .authenticating, .awaitingEmailConfirmation, .passwordRecovery, .sessionExpired:
                Label("Sign in from the Account tab to enable sync", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.secondary)
            case .signedIn:
                if !syncPersistentState.hasCompletedInitialSyncDecision {
                    Button("Set Up Sync") { isPresentingFirstSyncDecision = true }
                } else {
                    Toggle("Sync", isOn: Binding(
                        get: { isSyncEnabled },
                        set: { newValue in
                            if newValue {
                                isSyncEnabled = true
                                SyncPreference.setEnabled(true)
                                Task { await runSync() }
                            } else {
                                isConfirmingDisableSync = true
                            }
                        }
                    ))
                    if isSyncEnabled {
                        LabeledContent("Status", value: SyncCoordinator.shared.status.displayText)
                        if let lastSync = syncPersistentState.lastSuccessfulSyncAt {
                            LabeledContent("Last Synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                        }
                        let pendingCount = SyncOutbox.pendingChangeCount(store: SyncCoordinator.shared.stateStore)
                        if pendingCount > 0 {
                            LabeledContent("Waiting to Upload", value: "\(pendingCount)")
                        }
                        Button {
                            Task { await runSync() }
                        } label: {
                            if isPerformingSyncNow { ProgressView().controlSize(.small) } else { Text("Sync Now") }
                        }
                        .disabled(isPerformingSyncNow)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .confirmationDialog(
            "Turn off sync? Your events stay on this Mac exactly as they are — nothing is deleted, locally or in your account.",
            isPresented: $isConfirmingDisableSync, titleVisibility: .visible
        ) {
            Button("Turn Off Sync", role: .destructive) {
                isSyncEnabled = false
                SyncPreference.setEnabled(false)
                SyncCoordinator.shared.pauseForSignOut()
            }
        }
        .sheet(isPresented: $isPresentingFirstSyncDecision) {
            MacFirstSyncDecisionView { decision in
                switch decision {
                case .notNow:
                    SyncCoordinator.shared.deferInitialSyncDecision()
                    isSyncEnabled = false
                case .proceed(let uploadExisting):
                    SyncCoordinator.shared.recordInitialSyncDecision(uploadExistingLocalData: uploadExisting, context: modelContext)
                    isSyncEnabled = true
                    Task { await runSync() }
                }
                isPresentingFirstSyncDecision = false
            }
            .frame(minWidth: 420, minHeight: 320)
        }
    }

    private func runSync() async {
        isPerformingSyncNow = true
        await SyncCoordinator.shared.sync(context: modelContext, account: accountCoordinator)
        syncPersistentState = SyncCoordinator.shared.stateStore.load()
        isPerformingSyncNow = false
    }
}
