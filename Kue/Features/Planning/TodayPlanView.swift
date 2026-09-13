//
//  TodayPlanView.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "D. Today Plan". Reached from Home via a toolbar button
//  (`HomeView.swift`), presented as a sheet — the same "doesn't disturb Home's own
//  NavigationStack" precedent every other Home-launched sheet in this codebase already uses
//  (`EventUnavailableView`, `LockScreenEventSelectionView`), rather than overwriting Home's
//  own dated sections (requirement D). Everything here is read/act on an already-computed
//  `TodayPlan` from `TodayPlanViewModel` — no scoring logic lives in this file.
//

import SwiftUI
import SwiftData

struct TodayPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendarProvider) private var calendarProvider
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = TodayPlanViewModel()
    @State private var openEventID: UUID?
    @State private var openTaskEventID: UUID?
    @State private var outcomeRecommendation: PlanningRecommendation?
    @State private var editingRecommendation: PlanningRecommendation?
    @State private var focusAlert: String?
    @Query private var allEvents: [KueEvent]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await refresh() }
                .refreshable { await refresh() }
                .navigationDestination(item: $openEventID) { id in
                    if let event = allEvents.first(where: { $0.id == id }) {
                        EventDetailView(event: event)
                    } else {
                        EventUnavailableView()
                    }
                }
                .confirmationDialog(
                    "How did it go?", isPresented: Binding(get: { outcomeRecommendation != nil }, set: { if !$0 { outcomeRecommendation = nil } }),
                    presenting: outcomeRecommendation
                ) { recommendation in
                    outcomeButtons(for: recommendation)
                }
                .sheet(item: $editingRecommendation) { recommendation in
                    RecommendationEditSheet(recommendation: recommendation, onSave: { date in
                        Task { await applyEdit(recommendation, date: date) }
                    })
                }
                .alert("Focus", isPresented: Binding(get: { focusAlert != nil }, set: { if !$0 { focusAlert = nil } }), presenting: focusAlert) { _ in
                    Button("OK") {}
                } message: { message in
                    Text(message)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.plan == nil {
            ProgressView("Building your plan…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = viewModel.plan {
            if let empty = plan.emptyStateMessage {
                ContentUnavailableView {
                    Label("All Clear", systemImage: "checkmark.circle")
                } description: {
                    Text(empty)
                }
                .accessibilityIdentifier("todayPlanEmptyState")
            } else {
                planList(plan)
            }
        } else {
            ContentUnavailableView("Smart Planning Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't build today's plan."))
        }
    }

    private func planList(_ plan: TodayPlan) -> some View {
        List {
            Section {
                LabeledContent("Date", value: plan.date.formatted(date: .complete, time: .omitted))
                LabeledContent("Completed Today", value: "\(plan.completedTodayCount) of \(plan.totalTodayCount)")
            }
            if let notice = plan.limitedInformationNotice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let top = plan.mostImportantAction {
                Section("Most Important") {
                    recommendationRow(top)
                }
                .accessibilityIdentifier("mostImportantActionSection")
            }
            if !plan.focusBlocks.isEmpty {
                Section("Focus Blocks") {
                    ForEach(plan.focusBlocks) { block in
                        focusBlockRow(block)
                    }
                }
            }
            if !plan.conflicts.isEmpty {
                Section("Scheduling Conflicts") {
                    ForEach(plan.conflicts) { recommendationRow($0) }
                }
            }
            if !plan.urgentItems.isEmpty {
                Section("Needs Attention") {
                    ForEach(plan.urgentItems) { recommendationRow($0) }
                }
            }
            if !plan.preparationRisks.isEmpty {
                Section("Preparation Risk") {
                    ForEach(plan.preparationRisks) { recommendationRow($0) }
                }
            }
            let remainder = plan.orderedRecommendations.filter {
                $0.category != .workOnNext && !plan.conflicts.contains($0) && !plan.urgentItems.contains($0) && !plan.preparationRisks.contains($0)
            }
            if !remainder.isEmpty {
                Section("Also Worth a Look") {
                    ForEach(remainder) { recommendationRow($0) }
                }
            }
        }
        .accessibilityIdentifier("todayPlanList")
    }

    private func recommendationRow(_ recommendation: PlanningRecommendation) -> some View {
        RecommendationRow(
            recommendation: recommendation,
            onAccept: { Task { await accept(recommendation) } },
            onEdit: { editingRecommendation = recommendation },
            onDismiss: { dismissRecommendation(recommendation) },
            onSnooze: { snoozeRecommendation(recommendation) },
            onOpenEvent: { openEventID = recommendation.affectedEventIDs.first },
            onConfirmOutcome: { outcomeRecommendation = recommendation },
            onStartFocus: { Task { await startFocus(recommendation.focusBlock) } }
        )
    }

    private func focusBlockRow(_ block: FocusBlockProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.title).font(.body)
            Text("\(block.start.formatted(date: .omitted, time: .shortened)) – \(block.end.formatted(date: .omitted, time: .shortened)) · \(block.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Add to Calendar") { addToCalendar(block) }
                    .buttonStyle(.bordered)
                Button("Start Focus") { Task { await startFocus(block) } }
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityIdentifier("focusBlockRow-\(block.id)")
    }

    // MARK: - Actions

    @ViewBuilder
    private func outcomeButtons(for recommendation: PlanningRecommendation) -> some View {
        Button("Completed") { Task { await confirmOutcome(recommendation, as: .complete) } }
        Button("Skipped") { Task { await confirmOutcome(recommendation, as: .skip) } }
        Button("Cancelled", role: .destructive) { Task { await confirmOutcome(recommendation, as: .cancel) } }
        Button("Open Event to Reschedule") { openEventID = recommendation.affectedEventIDs.first }
        Button("Not Now", role: .cancel) {}
    }

    private func refresh() async {
        await viewModel.refresh(context: modelContext, calendarProvider: calendarProvider)
    }

    private func accept(_ recommendation: PlanningRecommendation) async {
        try? await PlanningActionRouter.accept(recommendation, context: modelContext)
        await refresh()
    }

    private func applyEdit(_ recommendation: PlanningRecommendation, date: Date) async {
        if let taskID = recommendation.affectedTaskIDs.first, let task = try? PlanningActionRouter.fetchTask(id: taskID, context: modelContext) {
            await TaskEditingService.rescheduleTask(task, to: date, context: modelContext)
        }
        RecommendationDismissalStore.dismiss(id: recommendation.id)
        await refresh()
    }

    private func dismissRecommendation(_ recommendation: PlanningRecommendation) {
        PlanningActionRouter.dismiss(recommendation)
        Task { await refresh() }
    }

    private func snoozeRecommendation(_ recommendation: PlanningRecommendation) {
        let until = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
        PlanningActionRouter.snooze(recommendation, until: until)
        Task { await refresh() }
    }

    private func confirmOutcome(_ recommendation: PlanningRecommendation, as choice: PlanningActionRouter.OutcomeChoice) async {
        try? await PlanningActionRouter.confirmOutcome(recommendation, as: choice, context: modelContext)
        outcomeRecommendation = nil
        await refresh()
    }

    private func addToCalendar(_ block: FocusBlockProposal) {
        do {
            let calendarID = calendarProvider.writableCalendars().first?.calendarIdentifier
            try PlanningActionRouter.addFocusBlockToCalendar(block, calendarProvider: calendarProvider, calendarIdentifier: calendarID)
            focusAlert = "Added \"\(block.title)\" to Calendar."
        } catch {
            focusAlert = "Couldn't add this to Calendar — Calendar access isn't available."
        }
    }

    private func startFocus(_ block: FocusBlockProposal?) async {
        guard let block, block.eventID != nil else {
            focusAlert = "This focus block isn't tied to a specific event, so Focus Mode isn't available for it."
            return
        }
        do {
            let outcome = try await PlanningActionRouter.startFocus(for: block, context: modelContext, manager: SystemLiveActivityManager.shared)
            switch outcome {
            case .started, .alreadyActiveForThisEvent:
                focusAlert = "Started Focus for \"\(block.title)\"."
            case .needsReplacementConfirmation:
                focusAlert = "Kue is already focused on another event. Open that event to switch focus."
            case .unavailable:
                focusAlert = "Focus Mode isn't available right now."
            }
        } catch {
            focusAlert = "Couldn't start Focus Mode."
        }
    }
}

/// Requirement F: "Edit Before Applying" — a minimal date/time picker, never a hidden
/// auto-apply. Reused for any recommendation carrying a `proposedDate`.
private struct RecommendationEditSheet: View {
    let recommendation: PlanningRecommendation
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(recommendation: PlanningRecommendation, onSave: @escaping (Date) -> Void) {
        self.recommendation = recommendation
        self.onSave = onSave
        _date = State(initialValue: recommendation.proposedDate ?? recommendation.focusBlock?.start ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("New Date", selection: $date)
                    .accessibilityIdentifier("recommendationEditDatePicker")
            }
            .navigationTitle(recommendation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(date); dismiss() }
                        .accessibilityIdentifier("recommendationEditSaveButton")
                }
            }
        }
    }
}

#Preview {
    TodayPlanView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}
