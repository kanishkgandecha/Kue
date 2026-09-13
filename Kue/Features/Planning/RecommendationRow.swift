//
//  RecommendationRow.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36. One recommendation, fully explained (requirement: "explain
//  every recommendation") plus whichever of Accept/Edit/Dismiss/Snooze/Open Event/Open Task/
//  Start Focus/Confirm Outcome apply to it (`recommendation.availableActions`) — this file
//  never decides *what* those actions do, only presents them; `TodayPlanView` supplies the
//  closures. Long titles/explanations wrap normally in a `VStack` (requirement K: "layouts
//  that survive long titles"); confidence is shown as text plus an icon, never color alone
//  (requirement K: "non-color-only risk indicators").
//

import SwiftUI

struct RecommendationRow: View {
    let recommendation: PlanningRecommendation
    var onAccept: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpenEvent: () -> Void
    var onConfirmOutcome: () -> Void
    var onStartFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: recommendation.category.systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(recommendation.title)
                    .font(.body.weight(.medium))
                Spacer()
                confidenceBadge
            }
            Text(recommendation.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !recommendation.contributingFactors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recommendation.contributingFactors, id: \.self) { factor in
                        Text("• \(factor)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let reason = recommendation.unavailableReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actionRow
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recommendation.category.displayName): \(recommendation.title). \(recommendation.explanation)")
        .accessibilityIdentifier("recommendation-\(recommendation.id)")
    }

    private var confidenceBadge: some View {
        // Text label, not color-only — requirement K.
        Text(recommendation.confidence.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Confidence: \(recommendation.confidence.rawValue)")
    }

    @ViewBuilder
    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recommendation.availableActions, id: \.self) { action in
                    button(for: action)
                }
            }
        }
    }

    @ViewBuilder
    private func button(for action: PlanningSuggestedAction) -> some View {
        switch action {
        case .accept:
            Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
        case .editBeforeApplying:
            Button("Edit", action: onEdit).buttonStyle(.bordered)
        case .dismiss:
            Button("Dismiss", action: onDismiss).buttonStyle(.bordered)
        case .snooze:
            Button("Snooze", action: onSnooze).buttonStyle(.bordered)
        case .openEvent:
            Button("Open Event", action: onOpenEvent).buttonStyle(.bordered)
        case .openTask:
            Button("Open Task", action: onOpenEvent).buttonStyle(.bordered) // task lives on its event's detail screen
        case .startFocus:
            Button("Start Focus", action: onStartFocus).buttonStyle(.bordered)
        case .addFocusBlockToCalendar:
            EmptyView() // surfaced directly on the focus-block row, not duplicated here
        case .confirmOutcome:
            Button("Confirm Outcome", action: onConfirmOutcome).buttonStyle(.borderedProminent)
        }
    }
}
