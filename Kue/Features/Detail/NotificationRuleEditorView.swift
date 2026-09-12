//
//  NotificationRuleEditorView.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Rule editor". One reusable sheet for
//  both an event-level rule and a task-level rule (`task` non-nil) — reachable from Event
//  Detail's Notifications tab and, lightly, from the task row it belongs to. Every save/delete
//  routes through this file directly (a `NotificationRule` mutation is plain SwiftData, not a
//  shared mutation service the way `EventActions` is — there is no existing "notification rule"
//  business logic anywhere else this could duplicate), then triggers the exact same
//  `NotificationEngine.reschedule` pass every other event mutation already does.
//

import SwiftUI
import SwiftData

struct NotificationRuleEditorView: View {
    let event: KueEvent
    var task: KueTask?
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

    /// Kue 3.0 Phase 7 — docs/35 "Per-event notification editor": "let the user override... an
    /// inherited rule for this event." Seeds every field from an Event Type default's own
    /// values, exactly as if the user had typed them in fresh — saving still always creates a
    /// genuine new *event*-level `NotificationRule` row, never mutates the shared default.
    init(event: KueEvent, task: KueTask? = nil, existingRule: NotificationRule? = nil, seedFromEventTypeDefault seed: NotificationRuleDefault? = nil) {
        self.event = event
        self.task = task
        self.existingRule = existingRule
        _anchor = State(initialValue: existingRule?.anchor ?? seed?.anchor.asRuleAnchor ?? (task != nil ? .taskDue : .eventStart))
        _offsetDirection = State(initialValue: existingRule?.offsetDirection ?? seed?.offsetDirection ?? .before)
        _offsetQuantity = State(initialValue: existingRule?.offsetQuantity ?? seed?.offsetQuantity ?? 30)
        _offsetUnit = State(initialValue: existingRule?.offsetUnit ?? seed?.offsetUnit ?? .minutes)
        _absoluteDate = State(initialValue: existingRule?.absoluteDate ?? .now.addingTimeInterval(3600))
        _isEnabled = State(initialValue: existingRule?.isEnabled ?? seed?.isEnabled ?? true)
        _customTitle = State(initialValue: existingRule?.customTitle ?? seed?.customTitle ?? "")
        _customBody = State(initialValue: existingRule?.customBody ?? seed?.customBody ?? "")
        _sound = State(initialValue: existingRule?.sound ?? seed?.sound ?? .defaultSound)
        _interruptionPreference = State(initialValue: existingRule?.interruptionPreference ?? seed?.interruptionPreference ?? .active)
        _snoozeMinutes = State(initialValue: existingRule?.snoozeMinutes ?? seed?.snoozeMinutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                        .accessibilityIdentifier("ruleEnabledToggle")
                    Picker("Type", selection: $anchor) {
                        if task == nil {
                            Text("Event Start").tag(NotificationRuleAnchor.eventStart)
                            Text("Event End").tag(NotificationRuleAnchor.eventEnd)
                            Text("Outcome Follow-Up").tag(NotificationRuleAnchor.outcomeFollowUp)
                        } else {
                            Text("Task Due").tag(NotificationRuleAnchor.taskDue)
                        }
                        Text("Custom Date").tag(NotificationRuleAnchor.absolute)
                    }
                    .accessibilityIdentifier("ruleAnchorPicker")
                }

                if anchor == .absolute {
                    Section("When") {
                        DatePicker("Date & Time", selection: $absoluteDate)
                            .accessibilityIdentifier("ruleAbsoluteDatePicker")
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
                        .accessibilityIdentifier("ruleOffsetDirectionPicker")
                        if offsetDirection != .at {
                            Stepper("\(offsetQuantity) \(offsetUnit.rawValue)", value: $offsetQuantity, in: 1...NotificationRuleValidator.maximumOffsetQuantity(for: offsetUnit))
                                .accessibilityIdentifier("ruleOffsetQuantityStepper")
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

                Section("Preview") {
                    Text(customTitle.isEmpty ? event.title : customTitle)
                        .fontWeight(.semibold)
                    Text(customBody.isEmpty ? "Kue will fill in a default message" : customBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let existingRule {
                    Section {
                        Button("Duplicate as New Rule") { duplicate(existingRule) }
                        Button("Delete", role: .destructive) { delete(existingRule) }
                            .accessibilityIdentifier("deleteRuleButton")
                    }
                }

                if let validationMessage {
                    Section { Text(validationMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existingRule == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("saveRuleButton")
                }
            }
        }
    }

    private func save() {
        let normalizedQuantity = offsetDirection == .at ? 0 : offsetQuantity
        do {
            try NotificationRuleValidator.validate(
                anchor: anchor, offsetDirection: offsetDirection, offsetQuantity: normalizedQuantity, offsetUnit: offsetUnit,
                absoluteDate: anchor == .absolute ? absoluteDate : nil,
                hasEventOwner: task == nil, hasTaskOwner: task != nil
            )
        } catch {
            validationMessage = "This rule isn't valid: \(error)"
            return
        }

        let rule = existingRule ?? NotificationRule(event: task == nil ? event : nil, task: task, anchor: anchor)
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
            if let task { task.notificationRules.append(rule) } else { event.notificationRules.append(rule) }
        }
        try? modelContext.save()
        // Kue 3.0 Phase 5 — docs/33 "Local outbox": a rule add/edit travels embedded in its
        // owning event's next graph push (`EventSyncRecord.notificationRules`), exactly like a
        // task edit already does — never its own separate sync record.
        SyncOutbox.markNotificationRulesDirty(owningEventID: rule.owningEventID ?? event.id)
        rescheduleAndDismiss()
    }

    private func delete(_ rule: NotificationRule) {
        let owningEventID = rule.owningEventID
        // Kue 3.0 Phase 7 correction (docs/35 "Audit") — a real defect this closes: captured
        // *before* deleting, since `NotificationEngine.reschedule`'s own diff-based cleanup can
        // only see identifiers still derivable from live data, and this rule's identifier
        // becomes unenumerable the instant it's deleted — without this, its pending
        // notification would never be removed and would fire indefinitely with stale content.
        let pendingIdentifier = rule.pendingRequestIdentifier
        modelContext.delete(rule)
        try? modelContext.save()
        // Requirement I: an explicit tombstone, never inferred from the rule's mere absence
        // the next time its owning event's graph happens to be pushed.
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
        if let task = rule.task { task.notificationRules.append(copy) } else if let event = rule.event { event.notificationRules.append(copy) }
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
