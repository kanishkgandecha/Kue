//
//  MacSmartPlanningSettingsView.swift
//  KueMac
//
//  Kue 3.0 Phase 8 — docs/36 "G." Mac Settings tab equivalent of
//  `Kue/Features/Settings/SmartPlanningSettingsView.swift` — same fields, same
//  `SmartPlanningPreferences`/`RecommendationDismissalStore` reads/writes, native `Form`
//  layout for the Settings window rather than the iPhone's list-in-a-sheet.
//

import SwiftUI

struct MacSmartPlanningSettingsView: View {
    @State private var preferences = SmartPlanningPreferences.current
    @State private var dismissedCount = RecommendationDismissalStore.count
    @State private var isShowingResetConfirmation = false

    var body: some View {
        Form {
            Toggle("Smart Planning", isOn: Binding(
                get: { preferences.masterEnabled },
                set: { preferences.masterEnabled = $0; save() }
            ))

            if preferences.masterEnabled {
                Section("Planning Hours") {
                    DatePicker("Start", selection: minutesBinding(\.planningWindowStartMinute), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: minutesBinding(\.planningWindowEndMinute), displayedComponents: .hourAndMinute)
                }

                Section("Workload") {
                    Stepper("Maximum daily items: \(preferences.maxDailyTaskLoad)", value: Binding(
                        get: { preferences.maxDailyTaskLoad },
                        set: { preferences.maxDailyTaskLoad = $0; save() }
                    ), in: 1...20)
                    Stepper("Focus block length: \(preferences.defaultFocusBlockMinutes) min", value: Binding(
                        get: { preferences.defaultFocusBlockMinutes },
                        set: { preferences.defaultFocusBlockMinutes = $0; save() }
                    ), in: 15...180, step: 15)
                }

                Section("Planning Intensity") {
                    Picker("Intensity", selection: Binding(
                        get: { preferences.intensity },
                        set: { preferences.intensity = $0; save() }
                    )) {
                        ForEach(PlanningIntensity.allCases, id: \.self) { intensity in
                            Text(intensity.displayName).tag(intensity)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(preferences.intensity.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data Sources") {
                    Toggle("Consider Calendar availability", isOn: Binding(
                        get: { preferences.considerCalendarAvailability },
                        set: { preferences.considerCalendarAvailability = $0; save() }
                    ))
                    Toggle("Use local productivity statistics", isOn: Binding(
                        get: { preferences.useLocalStatistics },
                        set: { preferences.useLocalStatistics = $0; save() }
                    ))
                }

                Section {
                    Button("Reset Dismissed Suggestions (\(dismissedCount))") {
                        isShowingResetConfirmation = true
                    }
                    .disabled(dismissedCount == 0)
                }
            }

            Section("Privacy") {
                Text("Smart Planning runs entirely on this Mac. Kue never uploads event titles, notes, locations, task titles, or the recommendations themselves. Local statistics, if enabled above, only ever use the same privacy-limited numbers already shown in Insights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset dismissed suggestions?", isPresented: $isShowingResetConfirmation, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                RecommendationDismissalStore.resetAll()
                dismissedCount = 0
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<SmartPlanningPreferences, Int>) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                return calendar.date(byAdding: .minute, value: preferences[keyPath: keyPath], to: calendar.startOfDay(for: .now)) ?? .now
            },
            set: { newDate in
                let calendar = Calendar.current
                let components = calendar.dateComponents([.hour, .minute], from: newDate)
                preferences[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                save()
            }
        )
    }

    private func save() {
        SmartPlanningPreferences.save(preferences)
    }
}
