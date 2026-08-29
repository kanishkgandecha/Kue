//
//  PreparationProgressView.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System, requirement 13's "improved preparation-progress
//  presentation." A compact, labeled progress bar — completed-task count over total — shown
//  on `EventCard` and available for Event Detail. Deliberately a determinate `ProgressView`
//  (not a custom-drawn ring): it's a native control that already respects Reduce Motion,
//  Increased Contrast, and Dynamic Type without this file doing anything extra, and the
//  fraction is always paired with a "N of M tasks" text label — never color/fill-level alone
//  (requirement 39).
//

import SwiftUI

struct PreparationProgressView: View {
    let completedCount: Int
    let totalCount: Int

    private var fraction: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: KueSpacing.xxs) {
            ProgressView(value: fraction)
                .tint(KueColor.accent)
            Text("\(completedCount) of \(totalCount) tasks")
                .font(KueTypography.footnote)
                .foregroundStyle(KueColor.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparation progress")
        .accessibilityValue("\(completedCount) of \(totalCount) tasks complete")
    }
}

#Preview {
    VStack(spacing: KueSpacing.lg) {
        PreparationProgressView(completedCount: 0, totalCount: 4)
        PreparationProgressView(completedCount: 2, totalCount: 4)
        PreparationProgressView(completedCount: 4, totalCount: 4)
    }
    .padding()
}
