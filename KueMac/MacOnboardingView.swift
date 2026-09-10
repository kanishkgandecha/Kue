//
//  MacOnboardingView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — concise first-run Mac onboarding. Reuses `OnboardingPreference` (Shared/)
//  verbatim — its App-Group-`UserDefaults` lookup already falls back to `.standard` when no
//  App Group entitlement is present (exactly the case on this sandboxed, App-Group-free Mac
//  target), so "completed" state is simply local to this Mac, never shared with the iPhone
//  install. No permission is requested here or anywhere else at launch — Calendar/notification
//  access (once those surfaces exist on Mac) is requested only when the user invokes them.
//

import SwiftUI

struct MacOnboardingView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to Kue for Mac")
                .font(.title).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                point("externaldrive", "Local-first storage", "Everything you create lives only on this Mac, in your own Application Support folder.")
                #if KUE_PERSONAL_BUILD
                point("iphone.slash", "No automatic iPhone sync yet", "This Personal build has no iCloud/CloudKit capability. Use Backup to move data between your iPhone and this Mac.")
                #else
                point("iphone.slash", "No automatic iPhone sync yet", "Phase 1 doesn't sync automatically with your iPhone. Use Backup to move data between devices.")
                #endif
                point("arrow.down.doc", "Move data with Backup", "Settings ▸ Backup exports and restores the same .kuebackup file format as the iPhone app.")
                point("hand.raised", "Permissions asked only when needed", "Kue never requests Calendar or notification access until you actually use a feature that needs it.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            Button("Get Started") {
                OnboardingPreference.markCompleted()
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
