//
//  MacStoreOpenFailureView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — the Mac equivalent of `Kue/Features/StoreRecovery/StoreOpenFailureView
//  .swift` (iOS-only, doesn't compile into this target). Same "recoverable diagnostic path,
//  never silently delete user data" contract (requirement 9, carried over from Kue 2.0 Phase
//  1): shows the real underlying error and the store's own on-disk location, offers no
//  "delete and start fresh" action.
//

import SwiftUI

struct MacStoreOpenFailureView: View {
    let diagnostic: StoreOpenDiagnostic

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Kue couldn't open its data")
                .font(.title2).fontWeight(.semibold)
            Text(diagnostic.errorDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GroupBox("Store location") {
                Text(diagnostic.storeURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Your data has not been deleted or modified. Quit and reopen Kue after resolving the issue, or contact support with the details above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 480)
    }
}
