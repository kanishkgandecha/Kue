//
//  AccountFirstSyncDecisionView.swift
//  Kue
//
//  Kue 3.0 Phase 5 — docs/33 "First-sync experience." Shown exactly once per account, the
//  first time the user turns Sync on — requirement J: "present clear choices based on actual
//  state... the user must understand what will happen... never silently replace local data,
//  never silently upload existing data, never delete either side as an initial-sync shortcut."
//
//  No sync jargon ("cursor," "revision," "conflict resolver") anywhere in this view's own copy
//  — only what the user actually needs to decide.
//

import SwiftUI
import SwiftData

struct AccountFirstSyncDecisionView: View {
    typealias Decision = AccountFirstSyncDecisionKind

    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var localEvents: [KueEvent]

    let onDecision: (Decision) -> Void

    @State private var isProbing = true
    @State private var remoteHasData: Bool?

    var body: some View {
        NavigationStack {
            Group {
                if isProbing {
                    ProgressView("Checking your account…")
                        .accessibilityIdentifier("firstSyncProbingIndicator")
                } else {
                    decisionContent
                }
            }
            .navigationTitle("Set Up Sync")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        onDecision(.notNow)
                        dismiss()
                    }
                    .accessibilityIdentifier("firstSyncNotNowButton")
                }
            }
        }
        .task {
            remoteHasData = await SyncCoordinator.shared.probeRemoteHasAnyData(account: accountCoordinator)
            isProbing = false
        }
    }

    private var hasLocalData: Bool { !localEvents.isEmpty }

    @ViewBuilder
    private var decisionContent: some View {
        switch (hasLocalData, remoteHasData) {
        case (false, false), (false, nil):
            // Requirement J: "neither" — nothing to move either direction; sync just starts
            // clean from here on.
            explanation(
                title: "Nothing to Set Up Yet",
                message: "You don't have any events on this device or in your account yet. Turning sync on now just means anything you add from here on stays in sync automatically.",
                primaryTitle: "Turn On Sync",
                primaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (true, false), (true, nil):
            // "local-only + empty cloud: offer to upload existing local data" — an explicit
            // offer, never automatic (requirement 8: "existing local data must never be
            // automatically uploaded without clear user consent").
            explanation(
                title: "Add This Device's Events to Your Account?",
                message: "This device has \(localEvents.count) event\(localEvents.count == 1 ? "" : "s") that aren't in your account yet. Add them now so they're available on your other devices too — nothing is deleted either way.",
                primaryTitle: "Add My Events",
                primaryAction: { onDecision(.proceed(uploadExistingLocalData: true)) },
                secondaryTitle: "Don't Add Them Yet",
                secondaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (false, true):
            // "empty local + cloud data: download safely" — no choice needed, downloading
            // can't lose anything since there's nothing local yet.
            explanation(
                title: "Download Your Events?",
                message: "Your account already has events from another device. Turning sync on will bring them to this device.",
                primaryTitle: "Turn On Sync",
                primaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (true, true):
            // "both contain data: offer a reviewed merge path" — the reviewed path here is
            // being explicit that nothing is replaced: local stays, cloud data arrives
            // alongside it, and any genuinely duplicate event (the same UUID on both sides —
            // vanishingly unlikely across devices that have never synced) resolves through the
            // same conflict policy every later sync uses, never a silent overwrite.
            explanation(
                title: "Combine This Device With Your Account?",
                message: "Both this device and your account have events. Turning on sync keeps everything from both — nothing here is deleted or replaced. If the exact same event ever exists in both places, Kue keeps the most recently edited version, never guesses, and never silently discards your work.",
                primaryTitle: "Combine Them",
                primaryAction: { onDecision(.proceed(uploadExistingLocalData: true)) }
            )
        }
    }

    private func explanation(
        title: String, message: String, primaryTitle: String, primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                primaryAction()
                dismiss()
            } label: {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("firstSyncPrimaryButton")

            if let secondaryTitle, let secondaryAction {
                Button {
                    secondaryAction()
                    dismiss()
                } label: {
                    Text(secondaryTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("firstSyncSecondaryButton")
            }
        }
        .padding()
    }
}
