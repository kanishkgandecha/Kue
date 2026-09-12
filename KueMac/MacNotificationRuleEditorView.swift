//
//  MacNotificationRuleEditorView.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Mac Notification Studio parity". The full
//  multi-field rule editor `MacEventDetailView`'s own header used to disclose as iPhone-only.
//  Same fields, same `NotificationRuleValidator`/`NotificationRule` model as
//  `NotificationRuleEditorView` (iPhone) — a native Mac `Form`/`.formStyle(.grouped)` sheet
//  with `MacEventEditorView`'s own window sizing/toolbar convention, not that iOS view embedded
//  here: no `NavigationStack` bar-title-display-mode iOS chrome, no iOS-only pickers.
//

import SwiftUI
import SwiftData

struct MacNotificationRuleEditorView: View {
    let event: KueEvent
    var existingRule: NotificationRule?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var anchor: NotificationRuleAnchor
    @State private var offsetDirection: NotificationOffsetDirection
    @State private var offsetQuantity: Int
    @State private var offsetUnit: NotificationOffsetUnit
    @State private var absoluteDate: Date
    @State private var isEnabled: Bool
    @State private var customTitle: String
    @State private var customBody: String
    @State private var sound: NotificationSoundOption
    @State private var interruptionPreference: NotificationInterruptionPreference
    @State private var snoozeMinutes: Int?
    @State private var validationMessage: String?

    /// Kue 3.0 Phase 7 — docs/35: same "seed an override from an inherited Event Type default"
    /// contract as iPhone's own `NotificationRuleEditorView`.
    init(event: KueEvent, existingRule: NotificationRule? = nil, seedFromEventTypeDefault seed: NotificationRuleDefault? = nil) {
        self.event = event
        self.existingRule = existingRule
        _anchor = State(initialValue: existingRule?.anchor ?? seed?.anchor.asRuleAnchor ?? .eventStart)
        _offsetDirection = State(initialValue: existingRule?.offsetDirection ?? seed?.offsetDirection ?? .before)
        _offsetQuantity = State(initialValue: existingRule?.offsetQuantity ?? seed?.offsetQuantity ?? 30)
        _offsetUnit = State(initialValue: existingRule?.offsetUnit ?? seed?.offsetUnit ?? .minutes)
        _absoluteDate = State(initialValue: existingRule?.absoluteDate ?? .now.addingTimeInterval(3600))
        _isEnabled = State(initialValue: existingRule?.isEnabled ?? seed?.isEnabled ?? true)
        _customTitle = State(initialValue: existingRule?.customTitle ?? seed?.customTitle ?? "")
        _customBody = State(initialValue: existingRule?.customBody ?? "")
        _sound = State(initialValue: existingRule?.sound ?? .defaultSound)
        _interruptionPreference = State(initialValue: existingRule?.interruptionPreference ?? .active)
        _snoozeMinutes = State(initialValue: existingRule?.snoozeMinutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                        .accessibilityIdentifier("macRuleEnabledToggle")
                    Picker("Type", selection: $anchor) {
                        Text("Event Start").tag(NotificationRuleAnchor.eventStart)
                        Text("Event End").tag(NotificationRuleAnchor.eventEnd)
                        Text("Outcome Follow-Up").tag(NotificationRuleAnchor.outcomeFollowUp)
                        Text("Custom Date").tag(NotificationRuleAnchor.absolute)
                    }
                    .accessibilityIdentifier("macRuleAnchorPicker")
                }

                if anchor == .absolute {
                    Section("When") {
                        DatePicker("Date & Time", selection: $absoluteDate)
                            .accessibilityIdentifier("macRuleAbsoluteDatePicker")
                        if NotificationRuleValidator.isAbsoluteDatePassed(absoluteDate, now: .now) {
                            Label("This date has already passed", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                } else if anchor != .outcomeFollowUp {
                    Section("Timing") {
                        Picker("Direction", selection: $offsetDirection) {
                            Text("Before").tag(NotificationOffsetDirection.before)
                            Text("At the time").tag(NotificationOffsetDirection.at)
                            Text("After").tag(NotificationOffsetDirection.after)
                        }
                        .accessibilityIdentifier("macRuleOffsetDirectionPicker")
                        if offsetDirection != .at {
                            Stepper("\(offsetQuantity) \(offsetUnit.rawValue)", value: $offsetQuantity, in: 1...NotificationRuleValidator.maximumOffsetQuantity(for: offsetUnit))
                                .accessibilityIdentifier("macRuleOffsetQuantityStepper")
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

                if let existingRule {
                    Section {
                        Button("Duplicate as New Rule") { duplicate(existingRule) }
                        Button("Delete", role: .destructive) { delete(existingRule) }
                            .accessibilityIdentifier("macDeleteRuleButton")
                    }
                }

                if let validationMessage {
                    Section { Text(validationMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingRule == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("macSaveRuleButton")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func save() {
        let normalizedQuantity = offsetDirection == .at ? 0 : offsetQuantity
        do {
            try NotificationRuleValidator.validate(
                anchor: anchor, offsetDirection: offsetDirection, offsetQuantity: normalizedQuantity, offsetUnit: offsetUnit,
                absoluteDate: anchor == .absolute ? absoluteDate : nil,
                hasEventOwner: true, hasTaskOwner: false
            )
        } catch {
            validationMessage = "This rule isn't valid: \(error)"
            return
        }

        let rule = existingRule ?? NotificationRule(event: event, anchor: anchor)
        rule.anchor = anchor
        rule.offsetDirection = offsetDirection
        rule.offsetQuantity = normalizedQuantity
        rule.offsetUnit = offsetUnit
        rule.absoluteDate = anchor == .absolute ? absoluteDate : nil
        rule.isEnabled = isEnabled
        rule.customTitle = customTitle.isEmpty ? nil : customTitle
        rule.customBody = customBody.isEmpty ? nil : customBody
        rule.sound = sound
        rule.interruptionPreference = interruptionPreference
        rule.snoozeMinutes = snoozeMinutes
        rule.updatedAt = .now

        if existingRule == nil {
            modelContext.insert(rule)
            event.notificationRules.append(rule)
        }
        try? modelContext.save()
        // Kue 3.0 Phase 5 — docs/33 "Local outbox": travels embedded in the owning event's
        // next graph push, exactly like a task edit already does.
        SyncOutbox.markNotificationRulesDirty(owningEventID: rule.owningEventID ?? event.id)
        rescheduleAndDismiss()
    }

    private func delete(_ rule: NotificationRule) {
        let owningEventID = rule.owningEventID
        // Kue 3.0 Phase 7 correction (docs/35 "Audit") — same real defect fixed on iPhone's
        // `NotificationRuleEditorView.delete(_:)`: captured before deletion, since the
        // identifier becomes unenumerable from live data afterward.
        let pendingIdentifier = rule.pendingRequestIdentifier
        modelContext.delete(rule)
        try? modelContext.save()
        SyncOutbox.markNotificationRuleDeleted(rule.id, owningEventID: owningEventID)
        if let pendingIdentifier {
            SystemNotificationScheduler.shared.removePendingNotificationRequests(withIdentifiers: [pendingIdentifier])
        }
        rescheduleAndDismiss()
    }

    private func duplicate(_ rule: NotificationRule) {
        let copy = NotificationRule(
            event: rule.event, task: rule.task, anchor: rule.anchor, offsetDirection: rule.offsetDirection,
            offsetQuantity: rule.offsetQuantity, offsetUnit: rule.offsetUnit, absoluteDate: rule.absoluteDate,
            isEnabled: rule.isEnabled, customTitle: rule.customTitle, customBody: rule.customBody,
            sound: rule.sound, interruptionPreference: rule.interruptionPreference, snoozeMinutes: rule.snoozeMinutes
        )
        modelContext.insert(copy)
        if let owningEvent = rule.event { owningEvent.notificationRules.append(copy) }
        try? modelContext.save()
        if let owningEventID = copy.owningEventID { SyncOutbox.markNotificationRulesDirty(owningEventID: owningEventID) }
        rescheduleAndDismiss()
    }

    private func rescheduleAndDismiss() {
        Task {
            await NotificationEngine.reschedule(
                context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity,
                scheduler: SystemNotificationScheduler.shared
            )
        }
        dismiss()
    }
}
