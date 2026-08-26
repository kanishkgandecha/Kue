//
//  StoreOpenFailureView.swift
//  Kue
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation, requirement 9: "Production migration
//  failure must present a recoverable diagnostic path and must never silently delete user
//  data." This is that path — shown by `KueApp` in place of `HomeView` whenever
//  `ModelContainerFactory.makeDefaultOrDiagnostic()` fails, instead of the previous hard
//  `fatalError` crash. Not a Kue 2.0 *feature* (requirement 13) — it adds no new product
//  capability, it's the safety net every app needs the moment it starts shipping real
//  migrations, and it was a genuine gap even under V1.0 alone (`makeDefault()`'s
//  `fatalError` is still there, unchanged, for callers that haven't opted into this path).
//
//  Deliberately does not offer any "delete and start fresh" action — requirement 9's "never
//  silently delete user data" reads naturally as "don't make deletion the easy button here
//  either." A failed open never touches the on-disk file at all (see
//  `ModelContainerFactory.makeDefaultThrowing()`), so the data this screen is reassuring the
//  user about is, factually, still there.
//

import SwiftUI

struct StoreOpenFailureView: View {
    let diagnostic: StoreOpenDiagnostic
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                VStack(spacing: 8) {
                    Text("Kue Couldn't Open Your Data")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    // The specific, factual reassurance requirement 9 calls for — never
                    // generic "something went wrong" copy (docs/13-error-handling.md).
                    Text("Your events haven't been deleted or changed. They're still on this device — Kue just couldn't open them this time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("storeOpenRetryButton")

                DisclosureGroup("Technical Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Location") {
                            Text(diagnostic.storeURL.path)
                        }
                        LabeledContent("Error") {
                            Text(diagnostic.errorDescription)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .accessibilityIdentifier("storeOpenDiagnosticDetails")
            }
            .padding()
            .frame(maxWidth: 480)
        }
        .accessibilityIdentifier("storeOpenFailureView")
    }
}

#Preview {
    StoreOpenFailureView(
        diagnostic: StoreOpenDiagnostic(
            storeURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/.../Kue.sqlite"),
            underlyingError: NSError(domain: "SwiftData", code: 1, userInfo: [NSLocalizedDescriptionKey: "Example error for preview"])
        ),
        onRetry: {}
    )
}
