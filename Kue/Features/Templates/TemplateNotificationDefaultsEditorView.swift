//
//  TemplateNotificationDefaultsEditorView.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults". Add/edit/delete/
//  duplicate for the built-in `Template.notificationRuleDefaults` array of a given `EventType`.
//  `Template` rows are created lazily (`TemplateStore.fetchOrCreateBuiltIn`) — opening this
//  screen is the first genuine "something needs this template row" moment for most event types,
//  matching `TemplateStore.swift`'s own header.
//
//  Deliberately its own, smaller editor rather than reusing `NotificationRuleEditorView`
//  directly: a template default is a plain `Codable` value with no SwiftData identity, no
//  `event`/`task` owner, and no `.absolute` anchor case (see `NotificationRuleDefault.swift`'s
//  own header) — every one of those differences would have turned "reuse" into more special-
//  casing than the shared UI structure (Form sections, pickers, stepper) is actually worth.
//

import SwiftUI
import SwiftData

struct TemplateNotificationDefaultsEditorView: View {
    let eventType: EventType

    @Environment(\.modelContext) private var modelContext
    @State private var template: Template?
    @State private var editingDefault: NotificationRuleDefault?
    @State private var isPresentingNewRule = false

    var body: some View {
        List {
            if let template, !template.notificationRuleDefaults.isEmpty {
                Section {
                    ForEach(template.notificationRuleDefaults) { ruleDefault in
                        Button {
                            editingDefault = ruleDefault
                        } label: {
                            TemplateNotificationDefaultRow(ruleDefault: ruleDefault)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(ruleDefault) }
                            Button("Duplicate") { duplicate(ruleDefault) }.tint(.blue)
                        }
                    }
                } footer: {
                    Text("Every event created as a \(eventType.displayName) gets these notification rules automatically. Editing them later never changes events you already created.")
                }
            } else {
                ContentUnavailableView(
                    "No Notification Defaults",
                    systemImage: "bell.slash",
                    description: Text("New \(eventType.displayName) events will use your global notification settings until you add one.")
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
                .accessibilityIdentifier("addTemplateNotificationDefaultButton")
            }
        }
        .onAppear {
            template = TemplateStore.fetchOrCreateBuiltIn(for: eventType, context: modelContext)
        }
        .sheet(isPresented: $isPresentingNewRule) {
            if let template {
                NotificationRuleDefaultEditorSheet(template: template, existingDefault: nil, onSave: reload)
            }
        }
        .sheet(item: $editingDefault) { ruleDefault in
            if let template {
                NotificationRuleDefaultEditorSheet(template: template, existingDefault: ruleDefault, onSave: reload)
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

private struct TemplateNotificationDefaultRow: View {
    let ruleDefault: NotificationRuleDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(anchorLabel)
                .font(.headline)
            Text(timingLabel)
                .font(KueTypography.footnote)
                .foregroundStyle(KueColor.secondaryText)
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

/// Add/edit sheet for one `NotificationRuleDefault`. Mutates `template.notificationRuleDefaults`
/// as a whole array on save — the property's own setter re-encodes it — rather than any
/// per-element SwiftData write, since this is a plain value array, not a relationship.
private struct NotificationRuleDefaultEditorSheet: View {
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
                    .accessibilityIdentifier("templateRuleAnchorPicker")
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
                            .accessibilityIdentifier("deleteTemplateRuleButton")
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
                        .accessibilityIdentifier("saveTemplateRuleButton")
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

#Preview("Template Notification Defaults") {
    NavigationStack {
        TemplateNotificationDefaultsEditorView(eventType: .exam)
    }
    .modelContainer(ModelContainerFactory.makeInMemory())
}
