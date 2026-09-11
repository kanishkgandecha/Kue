//
//  MacTemplateNotificationDefaultsEditorView.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults" / "Mac
//  Notification Studio parity". Native Mac equivalent of iPhone's
//  `TemplateNotificationDefaultsEditorView` (which lives under `Kue/`, the iPhone-only target
//  folder, and isn't part of the KueMac build) — same shared `TemplateStore`/
//  `NotificationRuleDefault` model, `MacEventEditorView`'s own window sizing/toolbar
//  convention rather than an embedded iPhone list.
//

import SwiftUI
import SwiftData

struct MacTemplateNotificationDefaultsEditorView: View {
    let eventType: EventType

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var template: Template?
    @State private var editingDefault: NotificationRuleDefault?
    @State private var isPresentingNewRule = false

    var body: some View {
        NavigationStack {
            List {
                if let template, !template.notificationRuleDefaults.isEmpty {
                    Section {
                        ForEach(template.notificationRuleDefaults) { ruleDefault in
                            Button {
                                editingDefault = ruleDefault
                            } label: {
                                MacTemplateNotificationDefaultRow(ruleDefault: ruleDefault)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit") { editingDefault = ruleDefault }
                                Button("Duplicate") { duplicate(ruleDefault) }
                                Button("Delete", role: .destructive) { delete(ruleDefault) }
                            }
                        }
                    } footer: {
                        Text("Every event created as a \(eventType.displayName) gets these notification rules automatically. Editing them later never changes events you already created.")
                    }
                } else {
                    ContentUnavailableView(
                        "No Notification Defaults", systemImage: "bell.slash",
                        description: Text("New \(eventType.displayName) events will use your global notification settings until you add one.")
                    )
                }
            }
            .navigationTitle("\(eventType.displayName) Notifications")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isPresentingNewRule = true } label: { Label("Add", systemImage: "plus") }
                        .accessibilityIdentifier("macAddTemplateNotificationDefaultButton")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            template = TemplateStore.fetchOrCreateBuiltIn(for: eventType, context: modelContext)
        }
        .sheet(isPresented: $isPresentingNewRule) {
            if let template {
                MacNotificationRuleDefaultEditorSheet(template: template, existingDefault: nil, onSave: reload)
            }
        }
        .sheet(item: $editingDefault) { ruleDefault in
            if let template {
                MacNotificationRuleDefaultEditorSheet(template: template, existingDefault: ruleDefault, onSave: reload)
            }
        }
    }

    private func reload() {
        template = TemplateStore.existingBuiltIn(for: eventType, context: modelContext)
    }

    private func delete(_ ruleDefault: NotificationRuleDefault) {
        guard let template else { return }
        template.notificationRuleDefaults.removeAll { $0.id == ruleDefault.id }
        try? modelContext.save()
        reload()
    }

    private func duplicate(_ ruleDefault: NotificationRuleDefault) {
        guard let template else { return }
        var copy = ruleDefault
        copy.id = UUID()
        template.notificationRuleDefaults.append(copy)
        try? modelContext.save()
        reload()
    }
}

private struct MacTemplateNotificationDefaultRow: View {
    let ruleDefault: NotificationRuleDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(anchorLabel).font(.headline)
            Text(timingLabel).font(.caption).foregroundStyle(.secondary)
            if !ruleDefault.isEnabled {
                Text("Disabled").font(.caption2).foregroundStyle(.orange)
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

private struct MacNotificationRuleDefaultEditorSheet: View {
    let template: Template
    let existingDefault: NotificationRuleDefault?
    let onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
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

    init(template: Template, existingDefault: NotificationRuleDefault?, onSave: @escaping () -> Void) {
        self.template = template
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
                    TextField("Custom Body (optional)", text: $customBody, axis: .vertical).lineLimit(2...4)
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
                    Picker("Default Snooze", selection: $snoozeMinutes) {
                        Text("10 minutes").tag(Int?.some(10))
                        Text("30 minutes").tag(Int?.some(30))
                        Text("1 hour").tag(Int?.some(60))
                        Text("Use global default").tag(Int?.none)
                    }
                }

                if existingDefault != nil {
                    Section {
                        Button("Delete", role: .destructive) { delete() }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("macSaveTemplateRuleButton")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
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

        if let existingDefault, let index = template.notificationRuleDefaults.firstIndex(where: { $0.id == existingDefault.id }) {
            template.notificationRuleDefaults[index] = candidate
        } else {
            template.notificationRuleDefaults.append(candidate)
        }
        try? modelContext.save()
        onSave()
        dismiss()
    }

    private func delete() {
        guard let existingDefault else { return }
        template.notificationRuleDefaults.removeAll { $0.id == existingDefault.id }
        try? modelContext.save()
        onSave()
        dismiss()
    }
}
