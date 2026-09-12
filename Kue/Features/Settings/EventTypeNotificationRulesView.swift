//
//  EventTypeNotificationRulesView.swift
//  Kue
//
//  Kue 3.0 Phase 7 — docs/35 "Notification Control Center." Add/edit/delete/duplicate for one
//  event type's own `EventTypeNotificationPreferences` rule list — the new **Event Type** scope
//  between Global Default and Specific Event (`NotificationPlanner`'s own precedence chain).
//
//  Deliberately mirrors `TemplateNotificationDefaultsEditorView`'s own shape almost verbatim —
//  same underlying value type (`NotificationRuleDefault`), same "no live event/task owner, no
//  `.absolute` anchor" constraints — rather than reusing `NotificationRuleEditorView` directly,
//  for the exact reason that file's own header already gives for the same choice.
//

import SwiftUI
import SwiftData

struct EventTypeNotificationRulesView: View {
    let eventType: EventType

    @Environment(\.modelContext) private var modelContext
    @State private var preferences = EventTypeNotificationPreferences.current
    @State private var editingDefault: NotificationRuleDefault?
    @State private var isPresentingNewRule = false

    private var rules: [NotificationRuleDefault] { preferences.rules(for: eventType) }

    var body: some View {
        List {
            if !rules.isEmpty {
                Section {
                    ForEach(rules) { ruleDefault in
                        Button {
                            editingDefault = ruleDefault
                        } label: {
                            EventTypeNotificationRuleRow(ruleDefault: ruleDefault)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(ruleDefault) }
                            Button("Duplicate") { duplicate(ruleDefault) }.tint(.blue)
                        }
                    }
                } footer: {
                    Text("Every \(eventType.displayName) event uses these rules unless a specific event overrides them. Global Default still applies to every other event type.")
                }
            } else {
                ContentUnavailableView(
                    "No \(eventType.displayName) Overrides",
                    systemImage: "bell.slash",
                    description: Text("\(eventType.displayName) events use your Global Default notification rules until you add one here.")
                )
            }
        }
        .navigationTitle("\(eventType.displayName) Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingNewRule = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("addEventTypeRuleButton")
            }
        }
        .sheet(isPresented: $isPresentingNewRule) {
            EventTypeNotificationRuleEditorSheet(eventType: eventType, existingDefault: nil, onSave: reload)
        }
        .sheet(item: $editingDefault) { ruleDefault in
            EventTypeNotificationRuleEditorSheet(eventType: eventType, existingDefault: ruleDefault, onSave: reload)
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

private struct EventTypeNotificationRuleRow: View {
    let ruleDefault: NotificationRuleDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(anchorLabel)
                .font(.headline)
            Text(timingLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !ruleDefault.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var anchorLabel: String {
        switch ruleDefault.anchor {
        case .eventStart: return "Event Start"
        case .eventEnd: return "Event End"
        case .outcomeFollowUp: return "Outcome Follow-Up"
        }
    }

    private var timingLabel: String {
        if ruleDefault.anchor == .outcomeFollowUp { return "After the event's outcome is recorded" }
        switch ruleDefault.offsetDirection {
        case .at: return "At the time"
        case .before: return "\(ruleDefault.offsetQuantity) \(ruleDefault.offsetUnit.rawValue) before"
        case .after: return "\(ruleDefault.offsetQuantity) \(ruleDefault.offsetUnit.rawValue) after"
        }
    }
}

private struct EventTypeNotificationRuleEditorSheet: View {
    let eventType: EventType
    let existingDefault: NotificationRuleDefault?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var anchor: TemplateNotificationAnchor
    @State private var offsetDirection: NotificationOffsetDirection
    @State private var offsetQuantity: Int
    @State private var offsetUnit: NotificationOffsetUnit
    @State private var isEnabled: Bool
    @State private var customTitle: String
    @State private var customBody: String
    @State private var sound: NotificationSoundOption
    @State private var interruptionPreference: NotificationInterruptionPreference
    @State private var snoozeMinutes: Int?
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
        _customTitle = State(initialValue: existingDefault?.customTitle ?? "")
        _customBody = State(initialValue: existingDefault?.customBody ?? "")
        _sound = State(initialValue: existingDefault?.sound ?? .defaultSound)
        _interruptionPreference = State(initialValue: existingDefault?.interruptionPreference ?? .active)
        _snoozeMinutes = State(initialValue: existingDefault?.snoozeMinutes)
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
                    .accessibilityIdentifier("eventTypeRuleAnchorPicker")
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

                Section("Message") {
                    TextField("Custom Title (optional)", text: $customTitle)
                    TextField("Custom Body (optional)", text: $customBody, axis: .vertical)
                        .lineLimit(2...4)
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

                if existingDefault != nil {
                    Section {
                        Button("Delete", role: .destructive) { delete() }
                            .accessibilityIdentifier("deleteEventTypeRuleButton")
                    }
                }

                if let validationMessage {
                    Section { Text(validationMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existingDefault == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("saveEventTypeRuleButton")
                }
            }
        }
    }

    private func save() {
        let normalizedQuantity = offsetDirection == .at ? 0 : offsetQuantity
        let candidate = NotificationRuleDefault(
            id: existingDefault?.id ?? UUID(), anchor: anchor, offsetDirection: offsetDirection,
            offsetQuantity: normalizedQuantity, offsetUnit: offsetUnit, isEnabled: isEnabled,
            customTitle: customTitle.isEmpty ? nil : customTitle, customBody: customBody.isEmpty ? nil : customBody,
            sound: sound, interruptionPreference: interruptionPreference, snoozeMinutes: snoozeMinutes
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

    private func delete() {
        guard let existingDefault else { return }
        var preferences = EventTypeNotificationPreferences.current
        var list = preferences.rulesByType[eventType] ?? []
        list.removeAll { $0.id == existingDefault.id }
        preferences.rulesByType[eventType] = list
        EventTypeNotificationPreferences.save(preferences)
        onSave()
        dismiss()
    }
}

#Preview("Event Type Notifications") {
    NavigationStack {
        EventTypeNotificationRulesView(eventType: .exam)
    }
}
