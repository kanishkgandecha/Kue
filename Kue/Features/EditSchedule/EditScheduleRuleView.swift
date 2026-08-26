//
//  EditScheduleRuleView.swift
//  Kue
//
//  Add/edit a single `ScheduleRule` — docs/09-screens-and-ux.md "Custom schedule editing":
//  "an add-row action that opens a small form (offset picker: N days/hours before; task
//  title field)". Minutes is added alongside days/hours so the minimum-lead-time validation
//  (docs/05-scheduling-engine.md) is actually reachable from the UI, not just the engine.
//

import SwiftUI

struct EditScheduleRuleView: View {
    enum Mode {
        case add
        case edit(index: Int)
    }

    let mode: Mode
    @Binding var rules: [ScheduleRule]

    @Environment(\.dismiss) private var dismiss

    @State private var unit: OffsetUnit = .days
    @State private var amount: Int = 1
    @State private var taskTitle: String = ""
    @State private var errors: [SchedulingEngine.CustomRuleValidationError] = []

    enum OffsetUnit: String, CaseIterable {
        case minutes = "Minutes"
        case hours = "Hours"
        case days = "Days"

        var range: ClosedRange<Int> {
            switch self {
            case .minutes: return 1...59
            case .hours: return 1...23
            case .days: return 1...SchedulingEngine.maxOffsetDays
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var offset: DateComponents {
        switch unit {
        case .minutes: return DateComponents(minute: amount)
        case .hours: return DateComponents(hour: amount)
        case .days: return DateComponents(day: amount)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Offset") {
                    Picker("Unit", selection: $unit) {
                        ForEach(OffsetUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("scheduleRuleUnitPicker")
                    .onChange(of: unit) { _, newUnit in
                        amount = min(amount, newUnit.range.upperBound)
                    }

                    Stepper(
                        "\(amount) \(unitLabel) before",
                        value: $amount,
                        in: unit.range
                    )
                    .accessibilityIdentifier("scheduleRuleAmountStepper")
                }

                Section("Task") {
                    TextField("Title", text: $taskTitle)
                        .accessibilityIdentifier("scheduleRuleTitleField")
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors) { error in
                            Label(error.errorDescription ?? "", systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("scheduleRuleErrors")
                }
            }
            .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("saveScheduleRuleButton")
                }
            }
            .onAppear(perform: loadExistingRuleIfEditing)
        }
    }

    private var unitLabel: String {
        let singular = String(unit.rawValue.dropLast())
        return amount == 1 ? singular : unit.rawValue.lowercased()
    }

    private func loadExistingRuleIfEditing() {
        guard case .edit(let index) = mode, rules.indices.contains(index) else { return }
        let rule = rules[index]
        taskTitle = rule.taskTitle
        if let day = rule.offset.day, day > 0 {
            unit = .days
            amount = day
        } else if let hour = rule.offset.hour, hour > 0 {
            unit = .hours
            amount = hour
        } else if let minute = rule.offset.minute, minute > 0 {
            unit = .minutes
            amount = minute
        }
    }

    /// Never writes a `KueTask` — only appends/replaces an in-memory `ScheduleRule`.
    /// `EditScheduleView` is what persists the rule set and regenerates tasks.
    private func save() {
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        errors = SchedulingEngine.validateCustomRule(offset: offset, taskTitle: trimmedTitle)
        guard errors.isEmpty else { return }

        let rule = ScheduleRule(offset: offset, taskTitle: trimmedTitle, isTimeSensitive: unit != .days)
        switch mode {
        case .add:
            rules.append(rule)
        case .edit(let index):
            rules[index] = rule
        }
        dismiss()
    }
}

#Preview {
    EditScheduleRuleView(mode: .add, rules: .constant([]))
}
