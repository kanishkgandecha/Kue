//
//  KueBanner.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. One consistent inline-banner treatment for every
//  "notice, but not blocking" surface in the app: ambiguity prompts, duplicate warnings,
//  low-confidence recognition, Calendar link-status notices. Requirement 26's "improve...
//  warning... states across the app" via one shared component rather than each screen
//  reinventing `Label(...).foregroundStyle(.orange)` slightly differently (which is exactly
//  what existed before this phase — see EventFormView/EventDetailView/OCRImportView's
//  pre-Phase-7 duplicate/ambiguity rows).
//
//  Plain `Label` + semantic color, not a glass surface — requirement 10: banners sit inside
//  forms and lists (dense content), which glass should never be forced onto.
//

import SwiftUI

enum KueBannerKind {
    case notice
    case warning
    case error

    var tint: Color {
        switch self {
        case .notice: return KueColor.accent
        case .warning: return KueColor.warning
        case .error: return KueColor.error
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .notice: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

struct KueBanner: View {
    let kind: KueBannerKind
    let message: String
    var systemImage: String?
    var action: (label: String, handler: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: KueSpacing.sm) {
            Label(message, systemImage: systemImage ?? kind.defaultSystemImage)
                .font(KueTypography.footnote)
                .foregroundStyle(kind.tint)
                // Requirement 38 — banner text must never truncate; it's advisory/blocking
                // copy the user needs to actually read.
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button(action.label, action: action.handler)
                    .font(KueTypography.footnote.weight(.semibold))
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: KueSpacing.lg) {
        KueBanner(kind: .notice, message: "Did you mean September 4th?", action: ("Resolved", {}))
        KueBanner(kind: .warning, message: "You already have \"Team Sync\" on this date.", action: ("View Event", {}))
        KueBanner(kind: .error, message: "Title can't be empty.")
    }
    .padding()
}
