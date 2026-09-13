//
//  SmartPlanningSettingsView.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "G. Preferences". Every field maps 1:1 to a
//  `SmartPlanningPreferences` field; saved immediately on change, same "no explicit Save
//  button" convention `NotificationStudioSettingsView` already establishes for its own global
//  preferences. Works fully signed-out/Personal-mode — everything here is App Group
//  `UserDefaults`, not gated on `AccountCoordinator` at all (requirement G).
//

import SwiftUI

struct SmartPlanningSettingsView: View {
    @State private var preferences = SmartPlanningPreferences.current
    @State private var dismissedCount = RecommendationDismissalStore.count
    @State private var isShowingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Smart Planning", isOn: Binding(
                    get: { preferences.masterEnabled },
                    set: { preferences.masterEnabled = $0; save() }
                ))
                .accessibilityIdentifier("smartPlanningMasterToggle")
            } footer: {
                Text("Kue analyzes your own events and tasks on this device to suggest a Today Plan, preparation sessions, and focus time. Nothing is uploaded — see Privacy below.")
            }

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

                Section("Working Days") {
                    ForEach(1...7, id: \.self) { weekday in
                        Toggle(weekdayName(weekday), isOn: Binding(
                            get: { preferences.workingWeekdays.contains(weekday) },
                            set: { isOn in
                                if isOn { preferences.workingWeekdays.insert(weekday) } else { preferences.workingWeekdays.remove(weekday) }
                                save()
                            }
                        ))
                    }
                }

                Section {
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
                } header: {
                    Text("Planning Intensity")
                } footer: {
                    Text("Intensity only changes thresholds — it never adds recommendations that aren't backed by your real events and tasks.")
                }

                Section {
                    Toggle("Consider Calendar availability", isOn: Binding(
                        get: { preferences.considerCalendarAvailability },
                        set: { preferences.considerCalendarAvailability = $0; save() }
                    ))
                    Toggle("Use local productivity statistics", isOn: Binding(
                        get: { preferences.useLocalStatistics },
                        set: { preferences.useLocalStatistics = $0; save() }
                    ))
                } header: {
                    Text("Data Sources")
                } footer: {
                    Text("Calendar availability uses Kue's existing Calendar permission — nothing new is requested here. If Calendar access isn't available, Kue plans using its own events only.")
                }

                Section {
                    Button("Reset Dismissed Suggestions (\(dismissedCount))") {
                        isShowingResetConfirmation = true
                    }
                    .disabled(dismissedCount == 0)
                    .accessibilityIdentifier("resetDismissedSuggestionsButton")
                }
            }

            Section {
                Text("Smart Planning runs entirely on this device. Kue never uploads event titles, notes, locations, task titles, or the recommendations themselves. If you enable local statistics above, only the same privacy-limited numbers already shown in Insights are used — never raw activity history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Smart Planning")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset dismissed suggestions?", isPresented: $isShowingResetConfirmation, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                RecommendationDismissalStore.resetAll()
                dismissedCount = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Suggestions you've dismissed or snoozed will be eligible to appear again.")
        }
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<SmartPlanningPreferences, Int>) -> Binding<Date> {
        Binding(
            get: {
                var calendar = Calendar.current
                calendar.timeZone = .current
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

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols[(weekday - 1 + symbols.count) % symbols.count]
    }

    private func save() {
        SmartPlanningPreferences.save(preferences)
    }
}

#Preview {
    NavigationStack { SmartPlanningSettingsView() }
}
