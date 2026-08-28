//
//  SystemIntegrationSettingsView.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "L." — the app-owned management
//  surface for Siri/Shortcuts/Spotlight/Controls, reached from Settings (no new bottom tab).
//  Explains what's available, shows/controls Spotlight indexing, and links to the Shortcuts
//  app where supported — Phase 7's design system throughout, same `Form`/`Section` idiom every
//  other Settings surface already uses.
//

import SwiftUI
import SwiftData

struct SystemIntegrationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.spotlightIndexer) private var spotlightIndexer

    @State private var isSpotlightEnabled = SpotlightIndexingPreference.isEnabled
    @State private var isRebuilding = false
    @State private var isRemoving = false
    @State private var lastActionMessage: String?

    var body: some View {
        Form {
            Section {
                Label("Siri & Shortcuts", systemImage: "mic.circle")
                    .font(KueTypography.cardTitle)
                Text("Ask Siri, or use the Shortcuts app, to create events, quick-add from a description, find or open an event, complete or snooze the next task, and start or stop Focus — all without opening Kue.")
                    .font(KueTypography.footnote)
                    .foregroundStyle(KueColor.secondaryText)
                Link("Open the Shortcuts App", destination: URL(string: "shortcuts://")!)
                    .accessibilityIdentifier("openShortcutsAppLink")
            } header: {
                Text("Siri & Shortcuts")
            }

            Section {
                Toggle("Spotlight Search", isOn: Binding(
                    get: { isSpotlightEnabled },
                    set: { newValue in
                        isSpotlightEnabled = newValue
                        SpotlightIndexingPreference.setEnabled(newValue)
                        Task {
                            if newValue {
                                await rebuildIndex()
                            } else {
                                await spotlightIndexer.removeAll()
                            }
                        }
                    }
                ))
                .accessibilityIdentifier("spotlightEnabledToggle")

                Button {
                    Task { await rebuildIndex() }
                } label: {
                    if isRebuilding {
                        ProgressView()
                    } else {
                        Text("Rebuild Spotlight Index")
                    }
                }
                .accessibilityIdentifier("rebuildSpotlightIndexButton")
                .disabled(isRebuilding || !isSpotlightEnabled)

                Button(role: .destructive) {
                    Task { await removeIndex() }
                } label: {
                    if isRemoving {
                        ProgressView()
                    } else {
                        Text("Remove Spotlight Entries")
                    }
                }
                .accessibilityIdentifier("removeSpotlightEntriesButton")
                .disabled(isRemoving)

                if let lastActionMessage {
                    Text(lastActionMessage)
                        .font(KueTypography.footnote)
                        .foregroundStyle(KueColor.secondaryText)
                        .accessibilityIdentifier("spotlightActionMessage")
                }
            } header: {
                Text("Spotlight")
            } footer: {
                // docs/24 "Privacy matrix" — exact field list, matches SpotlightEventPayload.
                Text("Kue indexes only an event's title, type, date, and status, on-device, for search and Siri Suggestions. Notes, locations, and anything recognized from screenshots or voice are never indexed.")
            }

            Section {
                Label("Control Center & Lock Screen", systemImage: "switch.2")
                    .font(KueTypography.cardTitle)
                Text("Add Quick Add, Show Next Event, Complete Next Task, and Stop Focus controls from the Controls gallery (long-press Control Center or your Lock Screen, then tap the add button). Actions that need you to choose an event open Kue instead of guessing.")
                    .font(KueTypography.footnote)
                    .foregroundStyle(KueColor.secondaryText)
            } header: {
                Text("Controls")
            }
        }
        .navigationTitle("Siri, Shortcuts & Spotlight")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rebuildIndex() async {
        isRebuilding = true
        let count = await SpotlightReconciliation.reindexAll(context: modelContext, indexer: spotlightIndexer)
        isRebuilding = false
        lastActionMessage = "Indexed \(count) event\(count == 1 ? "" : "s")."
    }

    private func removeIndex() async {
        isRemoving = true
        await spotlightIndexer.removeAll()
        isRemoving = false
        lastActionMessage = "Removed every Spotlight entry."
    }
}

#Preview("System Integration Settings — Light") {
    NavigationStack {
        SystemIntegrationSettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
}

#Preview("System Integration Settings — Dark") {
    NavigationStack {
        SystemIntegrationSettingsView()
            .modelContainer(ModelContainerFactory.makeInMemory())
    }
    .preferredColorScheme(.dark)
}
