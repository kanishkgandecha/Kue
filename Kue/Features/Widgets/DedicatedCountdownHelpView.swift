//
//  DedicatedCountdownHelpView.swift
//  Kue
//
//  See docs/22-expanded-and-dedicated-widgets.md "E." — reached via `kue://dedicated-
//  countdown-help` when a Dedicated Countdown widget's selected event is genuinely
//  unavailable (deleted, or the widget was never configured). There is no supported
//  WidgetKit/AppIntents API that lets this screen — or any in-app control — reconfigure one
//  specific already-placed widget instance; the system's own long-press → Edit Widget sheet
//  is the only way. This screen says so plainly rather than offering a button that would
//  falsely imply otherwise.
//

import SwiftUI

struct DedicatedCountdownHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: KueSpacing.lg) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: KueIconSize.extraLarge))
                    .foregroundStyle(KueColor.secondaryText)
                Text("Choose an Event")
                    .font(KueTypography.screenTitle)
                Text("This Dedicated Countdown widget's event isn't available anymore, or hasn't been chosen yet. Long-press the widget on your Home Screen or Lock Screen and choose Edit Widget to pick one.")
                    .font(KueTypography.body)
                    .foregroundStyle(KueColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(KueSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KueColor.screenBackground)
            .navigationTitle("Dedicated Countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("dedicatedCountdownHelpDoneButton")
                }
            }
        }
        .accessibilityIdentifier("dedicatedCountdownHelpView")
    }
}

#Preview("Dedicated Countdown Help — Light") {
    DedicatedCountdownHelpView()
}

#Preview("Dedicated Countdown Help — Dark") {
    DedicatedCountdownHelpView()
        .preferredColorScheme(.dark)
}
