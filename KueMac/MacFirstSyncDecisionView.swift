//
//  MacFirstSyncDecisionView.swift
//  KueMac
//
//  Kue 3.0 Phase 5 — docs/33 "First-sync experience." Native Mac counterpart to
//  `AccountFirstSyncDecisionView` (Kue/Features/Settings/, iPhone-only target) — same
//  decision logic and copy, `Form`-based instead of the iPhone sheet's centered VStack, since
//  KueMac has no shared-view target with the iPhone app (every Mac screen is its own file,
//  matching `MacAccountView`/`MacNotificationRuleEditorView`'s own established precedent).
//

import SwiftUI
import SwiftData

struct MacFirstSyncDecisionView: View {
    typealias Decision = AccountFirstSyncDecisionKind

    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var localEvents: [KueEvent]

    let onDecision: (Decision) -> Void

    @State private var isProbing = true
    @State private var remoteHasData: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isProbing {
                ProgressView("Checking your account…")
            } else {
                decisionContent
            }
            HStack {
                Spacer()
                Button("Not Now") {
                    onDecision(.notNow)
                    dismiss()
                }
            }
        }
        .padding(24)
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
            explanation(
                title: "Nothing to Set Up Yet",
                message: "You don't have any events on this Mac or in your account yet. Turning sync on now just means anything you add from here on stays in sync automatically.",
                primaryTitle: "Turn On Sync", primaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (true, false), (true, nil):
            explanation(
                title: "Add This Mac's Events to Your Account?",
                message: "This Mac has \(localEvents.count) event\(localEvents.count == 1 ? "" : "s") that aren't in your account yet. Add them now so they're available on your other devices too — nothing is deleted either way.",
                primaryTitle: "Add My Events", primaryAction: { onDecision(.proceed(uploadExistingLocalData: true)) },
                secondaryTitle: "Don't Add Them Yet", secondaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (false, true):
            explanation(
                title: "Download Your Events?",
                message: "Your account already has events from another device. Turning sync on will bring them to this Mac.",
                primaryTitle: "Turn On Sync", primaryAction: { onDecision(.proceed(uploadExistingLocalData: false)) }
            )
        case (true, true):
            explanation(
                title: "Combine This Mac With Your Account?",
                message: "Both this Mac and your account have events. Turning on sync keeps everything from both — nothing here is deleted or replaced.",
                primaryTitle: "Combine Them", primaryAction: { onDecision(.proceed(uploadExistingLocalData: true)) }
            )
        }
    }

    private func explanation(
        title: String, message: String, primaryTitle: String, primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary)
            HStack {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) { secondaryAction(); dismiss() }
                }
                Spacer()
                Button(primaryTitle) { primaryAction(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
