//
//  TemplatesView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Screen inventory" — "Templates: Interview, Exam, Trip,
//  Deadline (built-in only — no custom in V1)". Picking one opens the same manual
//  EventFormView pre-set to that type, so creation runs through the identical deterministic
//  path (SchedulingEngine.regenerateTasks on save) — zero AI, nothing template-specific
//  beyond which `EventType` the form starts with. No `Template` rows are persisted — the
//  four built-in templates are just this static list plus
//  `SchedulingEngine.defaultRules(for:)`; there's nothing else to seed or migrate for a
//  fixed set that never changes (docs explicitly rule out user-created reusable templates).
//

import SwiftUI

struct TemplatesView: View {
    /// Hands the chosen type back to the caller. Kue 2.0 Phase 7 — Templates is its own
    /// bottom-navigation destination (`RootTabView`) rather than a sheet presented from Home,
    /// so `onSelect` now pushes the prefilled form onto Templates' *own* `NavigationStack`
    /// (see `RootTabView`'s `.navigationDestination(item:)`) instead of the old "dismiss this
    /// sheet, then have Home present another one" dance.
    let onSelect: (EventType) -> Void

    /// Built-in only, in the order docs/09-screens-and-ux.md lists them. `.generic` isn't a
    /// template — it's the Add screen's own default when nothing else applies. Requirement:
    /// "distinction between built-in templates and future user-created templates" — every row
    /// here is built-in by construction (this phase still doesn't implement user-created
    /// ones); the section header says so explicitly rather than leaving it implicit.
    private let templateTypes: [EventType] = [.interview, .exam, .trip, .deadline]

    var body: some View {
        List {
            Section {
                ForEach(templateTypes, id: \.self) { type in
                    Button {
                        onSelect(type)
                    } label: {
                        TemplateRow(eventType: type)
                    }
                    .accessibilityIdentifier("template-\(type.rawValue)")
                }
            } header: {
                Text("Built-In Templates")
            } footer: {
                Text("Each one pre-fills the event type and its default preparation schedule — everything stays editable before you save.")
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TemplateRow: View {
    let eventType: EventType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text(eventType.displayName)
                    .font(.headline)
            }
            Text(taskSummary)
                .font(KueTypography.footnote)
                .foregroundStyle(KueColor.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .foregroundStyle(.primary)
    }

    private var icon: String {
        switch eventType {
        case .generic: return "calendar"
        case .deadline: return "clock.badge.exclamationmark"
        case .exam: return "book.closed"
        case .interview: return "person.crop.circle.badge.questionmark"
        case .trip: return "airplane"
        }
    }

    /// A preview of what this template will schedule, e.g. "Preparation start · Technical
    /// review · Project/resume review · Final reminder" — proof it's "fully scheduled" with
    /// no extra tap needed to see what that means.
    private var taskSummary: String {
        SchedulingEngine.defaultRules(for: eventType).map(\.taskTitle).joined(separator: " · ")
    }
}

#Preview("Templates — Light") {
    NavigationStack {
        TemplatesView { _ in }
    }
}

#Preview("Templates — Dark") {
    NavigationStack {
        TemplatesView { _ in }
    }
    .preferredColorScheme(.dark)
}
