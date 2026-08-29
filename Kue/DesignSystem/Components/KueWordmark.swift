//
//  KueWordmark.swift
//  Kue
//
//  Kue 2.0 Phase 7 — centered Home wordmark. Renders the approved "KueWordmark" image set in
//  `Assets.xcassets` directly (light/dark variants and transparency are the asset catalog's own
//  automatic appearance metadata — this view never branches on `colorScheme` itself, and never
//  applies template rendering/recoloring, which would fight that metadata). No system-font
//  approximation of the wordmark exists anywhere in this app.
//

import SwiftUI

struct KueWordmark: View {
    var body: some View {
        Image("KueWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: 28)
            // Exactly "Kue", never interactive (no behavior is defined for tapping it).
            .accessibilityLabel("Kue")
            .accessibilityAddTraits(.isHeader)
            .accessibilityRemoveTraits(.isButton)
    }
}

#Preview("Wordmark — Light") {
    KueWordmark().padding()
}

#Preview("Wordmark — Dark") {
    KueWordmark().padding().preferredColorScheme(.dark)
}
