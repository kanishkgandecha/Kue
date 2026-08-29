//
//  EventUnavailableView.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "J." — reached via `kue://event/<uuid>` (the
//  same `KueDeepLink` a widget, notification, or Live Activity tap all already use) when the
//  targeted event no longer exists. Requirement: "an honest unavailable message, never a
//  silent no-op or a redirect to a different event" — mirrors
//  `DedicatedCountdownHelpView`'s own plain-explanation shape exactly, generalized to any
//  event-scoped deep link rather than just the Dedicated Countdown widget's.
//

import SwiftUI

struct EventUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: KueSpacing.lg) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: KueIconSize.extraLarge))
                    .foregroundStyle(KueColor.secondaryText)
                Text("Event Not Found")
                    .font(KueTypography.screenTitle)
                Text("This event isn't available anymore — it may have been deleted.")
                    .font(KueTypography.body)
                    .foregroundStyle(KueColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(KueSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KueColor.screenBackground)
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("eventUnavailableDoneButton")
                }
            }
        }
        .accessibilityIdentifier("eventUnavailableView")
    }
}

#Preview("Event Unavailable — Light") {
    EventUnavailableView()
}

#Preview("Event Unavailable — Dark") {
    EventUnavailableView()
        .preferredColorScheme(.dark)
}
