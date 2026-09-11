//
//  ApplyDefaultsToExistingEventsView.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Notification hierarchy": the
//  required preview-then-confirm surface for `NotificationDefaultsApplier`. Shows the exact
//  count before anything changes — never applies as a side effect of opening this sheet.
//

import SwiftUI
import SwiftData

struct ApplyDefaultsToExistingEventsView: View {
    let preferences: NotificationGlobalPreferences

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var events: [KueEvent]

    @State private var isConfirming = false
    @State private var didApply = false
    @State private var changedCount = 0

    private var preview: NotificationDefaultsApplyPreview {
        NotificationDefaultsApplier.preview(events: events, defaults: preferences)
    }

    var body: some View {
        NavigationStack {
            Form {
                if didApply {
                    Section {
                        Label("Applied to \(changedCount) event\(changedCount == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        LabeledContent("Events affected", value: "\(preview.affectedEventCount)")
                        LabeledContent("Event-start reminders to add", value: "\(preview.eventStartRulesToAdd)")
                        LabeledContent("Outcome follow-ups to add", value: "\(preview.outcomeFollowUpRulesToAdd)")
                    } header: {
                        Text("Summary")
                    } footer: {
                        Text("\(preview.existingOverridesPreserved) existing custom rule(s) will be preserved exactly as they are.")
                    }

                    Section {
                        Button("Apply to \(preview.affectedEventCount) Event\(preview.affectedEventCount == 1 ? "" : "s")") {
                            isConfirming = true
                        }
                        .disabled(preview.affectedEventCount == 0)
                        .accessibilityIdentifier("confirmApplyDefaultsButton")
                    }
                }
            }
            .navigationTitle("Apply Defaults")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didApply ? "Done" : "Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Apply the current global defaults to \(preview.affectedEventCount) existing event(s)? Events with their own custom rules are never changed.",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Apply") {
                    changedCount = NotificationDefaultsApplier.apply(events: events, defaults: preferences, context: modelContext)
                    didApply = true
                    Task {
                        await NotificationEngine.reschedule(context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity, scheduler: SystemNotificationScheduler.shared, globalPreferences: preferences)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
