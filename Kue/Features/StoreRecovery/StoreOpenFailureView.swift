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
        // Kue 2.0 Phase 7 — requirement 25: a calm, serious presentation, never implying data
        // loss. Deliberately plain content on `KueColor.screenBackground`, not a glass
        // surface — requirement 10, and this is exactly the kind of screen where translucency
        // would undermine, not support, the reassurance this view exists to give.
        ScrollView {
            VStack(spacing: KueSpacing.xl) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: KueIconSize.extraLarge))
                    .foregroundStyle(KueColor.warning)
                    .accessibilityHidden(true)

                VStack(spacing: KueSpacing.sm) {
                    Text("Kue Couldn't Open Your Data")
                        .font(KueTypography.screenTitle)
                        .multilineTextAlignment(.center)

                    // The specific, factual reassurance requirement 9/25 calls for — never
                    // generic "something went wrong" copy, never implying deletion
                    // (docs/13-error-handling.md).
                    Text("Your events haven't been deleted or changed. They're still on this device — Kue just couldn't open them this time.")
                        .font(KueTypography.body)
                        .foregroundStyle(KueColor.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Try Again", action: onRetry)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("storeOpenRetryButton")

                DisclosureGroup("Technical Details") {
                    VStack(alignment: .leading, spacing: KueSpacing.sm) {
                        LabeledContent("Location") {
                            Text(diagnostic.storeURL.path)
                        }
                        LabeledContent("Error") {
                            Text(diagnostic.errorDescription)
                        }
                    }
                    .font(KueTypography.footnote)
                    .foregroundStyle(KueColor.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, KueSpacing.xs)
                }
                .accessibilityIdentifier("storeOpenDiagnosticDetails")
            }
            .padding(KueSpacing.xl)
            .frame(maxWidth: 480)
        }
        .background(KueColor.screenBackground)
        .accessibilityIdentifier("storeOpenFailureView")
    }
}

private func previewDiagnostic() -> StoreOpenDiagnostic {
    StoreOpenDiagnostic(
        storeURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/.../Kue.sqlite"),
        underlyingError: NSError(domain: "SwiftData", code: 1, userInfo: [NSLocalizedDescriptionKey: "Example error for preview"])
    )
}

#Preview("Store Recovery — Light") {
    StoreOpenFailureView(diagnostic: previewDiagnostic(), onRetry: {})
}

#Preview("Store Recovery — Dark") {
    StoreOpenFailureView(diagnostic: previewDiagnostic(), onRetry: {})
        .preferredColorScheme(.dark)
}

#Preview("Store Recovery — Large Dynamic Type") {
    StoreOpenFailureView(diagnostic: previewDiagnostic(), onRetry: {})
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
