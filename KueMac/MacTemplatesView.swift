//
//  MacTemplatesView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — mirrors `Kue/Features/Templates/TemplatesView.swift` (iOS) exactly:
//  Kue 2.0 has no user-created, persisted template CRUD anywhere — a `Template` `@Model`
//  exists in the schema, but docs/09-screens-and-ux.md is explicit that V1/2.0's "Templates"
//  destination is four built-in event types plus `SchedulingEngine.defaultRules(for:)`,
//  nothing more, and no phase has ever built create/edit/delete for it. The Kue 3.0 Phase 1
//  spec describes full template CRUD; building that here would be inventing a feature that
//  doesn't exist anywhere else in Kue, on either platform, and duplicating a model/edit
//  surface nothing currently maintains — reported honestly in the final report rather than
//  silently built. This view offers exact current-behavior parity: pick a built-in type,
//  start a new event pre-set to it.
//

import SwiftUI

struct MacTemplatesView: View {
    var onStart: (EventType) -> Void

    private let templateTypes: [EventType] = [.interview, .exam, .trip, .deadline]

    var body: some View {
        List {
            Section {
                ForEach(templateTypes, id: \.self) { type in
                    Button { onStart(type) } label: {
                        MacTemplateRow(eventType: type)
                    }
                }
            } header: {
                Text("Built-In Templates")
            } footer: {
                Text("Each one pre-fills the event type and its default preparation schedule — everything stays editable before you save. Kue doesn't yet support custom, user-saved templates on either platform.")
            }
        }
        .navigationTitle("Templates")
    }
}

private struct MacTemplateRow: View {
    let eventType: EventType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(eventType.displayName, systemImage: icon)
                .font(.headline)
            let rules = SchedulingEngine.defaultRules(for: eventType)
            Text(rules.isEmpty ? "No default preparation tasks." : "\(rules.count) default preparation task\(rules.count == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch eventType {
        case .generic: return "calendar"
        case .deadline: return "flag"
        case .exam: return "graduationcap"
        case .interview: return "person.crop.circle"
        case .trip: return "airplane"
        }
    }
}
