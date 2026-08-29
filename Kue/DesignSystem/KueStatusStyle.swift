//
//  KueStatusStyle.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. The one place `EventStatus` (and the few other
//  status-shaped enums this app shows badges for) maps to a color + SF Symbol + label —
//  every status badge in the app (Home cards, Event Detail, filter sheet) reads from here, so
//  changing what "Active" looks like is a one-file edit, and — requirement 39 — every mapping
//  carries a label alongside its color/icon, since color or icon shape alone is never how a
//  state is conveyed here.
//

import SwiftUI

struct KueStatusStyle {
    let label: String
    let systemImage: String
    let tint: Color

    static func forEvent(_ event: KueEvent, status: EventStatus) -> KueStatusStyle {
        // Requirement: skip/cancel both derive `.cancelled` from EventStatusEngine, but must
        // read distinctly — checked first, same rule EventRow/EventDetailView already follow.
        if event.isSkipped {
            return KueStatusStyle(label: "Skipped", systemImage: "arrow.uturn.forward.circle", tint: KueColor.disabled)
        }
        switch status {
        case .draft:
            return KueStatusStyle(label: "Draft", systemImage: "pencil.circle", tint: KueColor.disabled)
        case .upcoming:
            return KueStatusStyle(label: "Upcoming", systemImage: "calendar", tint: KueColor.secondaryText)
        case .preparing:
            return KueStatusStyle(label: "Preparing", systemImage: "checklist", tint: KueColor.accent)
        case .tomorrow:
            return KueStatusStyle(label: "Tomorrow", systemImage: "clock", tint: KueColor.urgent)
        case .today:
            return KueStatusStyle(label: "Today", systemImage: "clock.badge.exclamationmark", tint: KueColor.urgent)
        case .active:
            return KueStatusStyle(label: "Active", systemImage: "play.circle.fill", tint: KueColor.active)
        case .awaitingOutcome:
            // Kue 2.0 Phase 10.1 — docs/25 "A.": the one consistent user-facing label for a
            // past event with no confirmed outcome. `.warning` (not `.completed`/`.disabled`)
            // so it reads as needing attention, not as a settled state.
            return KueStatusStyle(label: "Needs Review", systemImage: "questionmark.circle", tint: KueColor.warning)
        case .completed:
            return KueStatusStyle(label: "Completed", systemImage: "checkmark.circle.fill", tint: KueColor.completed)
        case .cancelled:
            return KueStatusStyle(label: "Cancelled", systemImage: "xmark.circle", tint: KueColor.disabled)
        case .archived:
            return KueStatusStyle(label: "Archived", systemImage: "archivebox", tint: KueColor.disabled)
        }
    }
}

/// A compact, glass-capable status pill — used on `EventCard` and anywhere else a status
/// needs to read at a glance without a full row. Icon + label together (never color alone).
struct EventStatusBadge: View {
    let style: KueStatusStyle

    var body: some View {
        Label(style.label, systemImage: style.systemImage)
            .font(KueTypography.statusLabel)
            .foregroundStyle(style.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, KueSpacing.sm)
            .padding(.vertical, KueSpacing.xxs)
            .kueGlassPill(tint: style.tint.opacity(0.15))
    }
}

#Preview("Status Badges — Light") {
    VStack(alignment: .leading, spacing: KueSpacing.sm) {
        ForEach([EventStatus.upcoming, .preparing, .tomorrow, .today, .active, .awaitingOutcome, .completed, .cancelled, .archived], id: \.self) { status in
            EventStatusBadge(style: KueStatusStyle(label: status.rawValue.capitalized, systemImage: "circle.fill", tint: .blue))
        }
    }
    .padding()
}
