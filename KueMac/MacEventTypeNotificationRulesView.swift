//
//  MacEventTypeNotificationRulesView.swift
//  KueMac
//
//  Kue 3.0 Phase 7 — docs/35 "Notification Control Center." Native macOS counterpart to
//  iPhone's `EventTypeNotificationRulesView` — same `EventTypeNotificationPreferences`, same
//  `NotificationRuleDefault` shape, same validation, native `Form`/`.formStyle(.grouped)`
//  presented as a sheet from `MacSettingsView` (that tab has no navigation stack of its own).
//

import SwiftUI
import SwiftData

struct MacEventTypeNotificationRulesView: View {
    let eventType: EventType

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = EventTypeNotificationPreferences.current
    @State private var editingDefault: NotificationRuleDefault?
    @State private var isPresentingNewRule = false

    private var rules: [NotificationRuleDefault] { preferences.rules(for: eventType) }

    var body: some View {
        Form {
            if !rules.isEmpty {
                Section {
                    ForEach(rules) { ruleDefault in
                        Button {
                            editingDefault = ruleDefault
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(anchorLabel(ruleDefault))
                                    Text(timingLabel(ruleDefault)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !ruleDefault.isEnabled { Text("Disabled").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Duplicate") { duplicate(ruleDefault) }
                            Button("Delete", role: .destructive) { delete(ruleDefault) }
                        }
                    }
                } footer: {
                    Text("Every \(eventType.displayName) event uses these rules unless a specific event overrides them.")
                }
            } else {
                Text("\(eventType.displayName) events use your Global Default notification rules until you add one here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(eventType.displayName) Notifications")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add") { isPresentingNewRule = true }
                    .accessibilityIdentifier("macAddEventTypeRuleButton")
            }
        }
        .sheet(isPresented: $isPresentingNewRule) {
            MacEventTypeNotificationRuleEditorSheet(eventType: eventType, existingDefault: nil, onSave: reload)
        }
        .sheet(item: $editingDefault) { ruleDefault in
            MacEventTypeNotificationRuleEditorSheet(eventType: eventType, existingDefault: ruleDefault, onSave: reload)
        }
    }

    private func anchorLabel(_ ruleDefault: NotificationRuleDefault) -> String {
        switch ruleDefault.anchor {
        case .eventStart: return "Event Start"
        case .eventEnd: return "Event End"
        case .outcomeFollowUp: return "Outcome Follow-Up"
        }
    }

    private func timingLabel(_ ruleDefault: NotificationRuleDefault) -> String {
        if ruleDefault.anchor == .outcomeFollowUp { return "After the event's outcome is recorded" }
        switch ruleDefault.offsetDirection {
        case .at: return "At the time"
        case .before: return "\(ruleDefault.offsetQuantity) \(ruleDefault.offsetUnit.rawValue) before"
        case .after: return "\(ruleDefault.offsetQuantity) \(ruleDefault.offsetUnit.rawValue) after"
        }
    }

    private func reload() {
        preferences = EventTypeNotificationPreferences.current
    }

    private func delete(_ ruleDefault: NotificationRuleDefault) {
        var updated = preferences
        var list = updated.rulesByType[eventType] ?? []
        list.removeAll { $0.id == ruleDefault.id }
        updated.rulesByType[eventType] = list
        EventTypeNotificationPreferences.save(updated)
        reload()
        rescheduleAfterChange()
    }

    private func duplicate(_ ruleDefault: NotificationRuleDefault) {
        var updated = preferences
        var copy = ruleDefault
        copy.id = UUID()
        updated.rulesByType[eventType, default: []].append(copy)
        EventTypeNotificationPreferences.save(updated)
        reload()
        rescheduleAfterChange()
    }

    private func rescheduleAfterChange() {
        Task {
            await NotificationEngine.reschedule(
                context: modelContext,
                intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity,
                scheduler: SystemNotificationScheduler.shared
            )
        }
    }
}

private struct MacEventTypeNotificationRuleEditorSheet: View {
    let eventType: EventType
    let existingDefault: NotificationRuleDefault?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var anchor: TemplateNotificationAnchor
    @State private var offsetDirection: NotificationOffsetDirection
    @State private var offsetQuantity: Int
    @State private var offsetUnit: NotificationOffsetUnit
    @State private var isEnabled: Bool
    @State private var sound: NotificationSoundOption
    @State private var interruptionPreference: NotificationInterruptionPreference
    @State private var validationMessage: String?

    init(eventType: EventType, existingDefault: NotificationRuleDefault?, onSave: @escaping () -> Void) {
        self.eventType = eventType
        self.existingDefault = existingDefault
        self.onSave = onSave
        _anchor = State(initialValue: existingDefault?.anchor ?? .eventStart)
        _offsetDirection = State(initialValue: existingDefault?.offsetDirection ?? .before)
        _offsetQuantity = State(initialValue: existingDefault?.offsetQuantity ?? 30)
        _offsetUnit = State(initialValue: existingDefault?.offsetUnit ?? .minutes)
        _isEnabled = State(initialValue: existingDefault?.isEnabled ?? true)
        _sound = State(initialValue: existingDefault?.sound ?? .defaultSound)
        _interruptionPreference = State(initialValue: existingDefault?.interruptionPreference ?? .active)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                    Picker("Type", selection: $anchor) {
                        Text("Event Start").tag(TemplateNotificationAnchor.eventStart)
                        Text("Event End").tag(TemplateNotificationAnchor.eventEnd)
                        Text("Outcome Follow-Up").tag(TemplateNotificationAnchor.outcomeFollowUp)
                    }
                }
                if anchor != .outcomeFollowUp {
                    Section("Timing") {
                        Picker("Direction", selection: $offsetDirection) {
                            Text("Before").tag(NotificationOffsetDirection.before)
                            Text("At the time").tag(NotificationOffsetDirection.at)
                            Text("After").tag(NotificationOffsetDirection.after)
                        }
                        if offsetDirection != .at {
                            Stepper("\(offsetQuantity) \(offsetUnit.rawValue)", value: $offsetQuantity, in: 1...NotificationRuleValidator.maximumOffsetQuantity(for: offsetUnit))
                            Picker("Unit", selection: $offsetUnit) {
                                ForEach(NotificationOffsetUnit.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                        }
                    }
                }
                Section("Sound & Interruption") {
                    Picker("Sound", selection: $sound) {
                        Text("Default").tag(NotificationSoundOption.defaultSound)
                        Text("Silent").tag(NotificationSoundOption.silent)
                    }
                    Picker("Interruption", selection: $interruptionPreference) {
                        Text("Passive").tag(NotificationInterruptionPreference.passive)
                        Text("Active").tag(NotificationInterruptionPreference.active)
                        Text("Time-Sensitive").tag(NotificationInterruptionPreference.timeSensitive)
                    }
                }
                if let validationMessage {
                    Section { Text(validationMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingDefault == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
    }

    private func save() {
        let normalizedQuantity = offsetDirection == .at ? 0 : offsetQuantity
        let candidate = NotificationRuleDefault(
            id: existingDefault?.id ?? UUID(), anchor: anchor, offsetDirection: offsetDirection,
            offsetQuantity: normalizedQuantity, offsetUnit: offsetUnit, isEnabled: isEnabled,
            sound: sound, interruptionPreference: interruptionPreference
        )
        do {
            try candidate.validate()
        } catch {
            validationMessage = "This rule isn't valid: \(error)"
            return
        }
        var preferences = EventTypeNotificationPreferences.current
        var list = preferences.rulesByType[eventType] ?? []
        if let existingDefault, let index = list.firstIndex(where: { $0.id == existingDefault.id }) {
            list[index] = candidate
        } else {
            list.append(candidate)
        }
        preferences.rulesByType[eventType] = list
        EventTypeNotificationPreferences.save(preferences)
        onSave()
        dismiss()
    }
}
