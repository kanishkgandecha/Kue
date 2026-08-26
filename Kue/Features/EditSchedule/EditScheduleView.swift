//
//  EditScheduleView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Custom schedule editing" — list/add/edit/swipe-to-delete
//  `ScheduleRule` entries, sorted by computed due date (no manual reordering — requirement
//  6). Saving replaces `KueSchedule.rules`, sets `isCustom = true`, and regenerates tasks
//  through `SchedulingEngine.regenerateTasks` — this screen never inserts a `KueTask` itself.
//

import SwiftUI
import SwiftData

struct EditScheduleView: View {
    @Bindable var event: KueEvent

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var rules: [ScheduleRule]
    @State private var isAddingRule = false
    @State private var editingIndex: Int?

    init(event: KueEvent) {
        self.event = event
        _rules = State(initialValue: event.schedule?.rules ?? SchedulingEngine.defaultRules(for: event.eventType))
    }

    /// Requirement: "list rules sorted by computed due date" — never reordered by hand.
    private var sortedIndices: [Int] {
        rules.indices.sorted { lhs, rhs in
            dueDate(for: rules[lhs]) < dueDate(for: rules[rhs])
        }
    }

    private func dueDate(for rule: ScheduleRule) -> Date {
        SchedulingEngine.dueDate(for: rule.offset, startDate: event.startDate, timeZoneIdentifier: event.timeZoneIdentifier) ?? .distantFuture
    }

    var body: some View {
        NavigationStack {
            List {
                if rules.isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "list.bullet",
                        description: Text("Add a rule to build this event's preparation schedule.")
                    )
                } else {
                    ForEach(sortedIndices, id: \.self) { index in
                        Button {
                            editingIndex = index
                        } label: {
                            ScheduleRuleRow(rule: rules[index], dueDate: dueDate(for: rules[index]))
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                rules.remove(at: index)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("scheduleRuleList")
            .navigationTitle("Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingRule = true
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addScheduleRuleButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("saveScheduleButton")
                        .disabled(rules.isEmpty)
                }
            }
            .sheet(isPresented: $isAddingRule) {
                EditScheduleRuleView(mode: .add, rules: $rules)
            }
            .sheet(isPresented: isEditingRule) {
                EditScheduleRuleView(mode: .edit(index: editingIndex ?? 0), rules: $rules)
            }
        }
    }

    private var isEditingRule: Binding<Bool> {
        Binding(get: { editingIndex != nil }, set: { if !$0 { editingIndex = nil } })
    }

    /// Requirement 7: replace the rules, mark custom, validate is already done per-rule in
    /// `EditScheduleRuleView` (nothing invalid can be in `rules` at this point), regenerate.
    /// Requirement 8: never writes a `KueTask` here — `regenerateTasks` owns that entirely.
    private func save() {
        let schedule: KueSchedule
        if let existing = event.schedule {
            schedule = existing
        } else {
            schedule = KueSchedule(event: event, templateType: .custom)
            modelContext.insert(schedule)
            event.schedule = schedule
        }
        schedule.rules = rules
        schedule.isCustom = true
        schedule.generatedAt = .now

        // docs/08-notifications.md "Deduplication": capture this event's prior identifiers
        // *before* `regenerateTasks` deletes the old (non-completed) tasks below — see
        // EventFormView.save()'s identical comment.
        let staleIdentifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
        SchedulingEngine.regenerateTasks(for: event, context: modelContext)
        EventActions.reloadWidget()
        if !staleIdentifiers.isEmpty {
            SystemNotificationScheduler.shared.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }
        // docs/08-notifications.md requirement 3/4: a custom schedule changes this event's
        // task due dates, so its pending "task due" requests (and possibly its preparation-
        // start timing) need to be replaced immediately, same as any other edit.
        Task {
            let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
            await NotificationEngine.reschedule(
                context: modelContext,
                intensity: intensity,
                scheduler: SystemNotificationScheduler.shared,
                requestPermissionIfNeeded: true
            )
        }
        dismiss()
    }
}

private struct ScheduleRuleRow: View {
    let rule: ScheduleRule
    let dueDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.taskTitle)
            Text(SchedulingEngine.offsetLabel(rule.offset))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let container = ModelContainerFactory.makeInMemory()
    let event = KueEvent(title: "Preview Event", eventType: .interview, startDate: .now.addingTimeInterval(10 * 86_400), estimatedDurationMinutes: 60, source: .manual)
    container.mainContext.insert(event)
    return EditScheduleView(event: event)
        .modelContainer(container)
}
