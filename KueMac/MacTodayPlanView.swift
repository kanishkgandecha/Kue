//
//  MacTodayPlanView.swift
//  KueMac
//
//  Kue 3.0 Phase 8 — docs/36 "D. Today Plan". A native two-column Mac layout (a scrollable
//  recommendation list on the left, the selected recommendation's full detail/actions on the
//  right) — not the iPhone sheet enlarged (requirement D: "do not simply enlarge the iPhone
//  screen"). Lives in `RootSplitView`'s own `content` column as the `.plan` sidebar
//  destination; opening an event from a recommendation sets `selectedEventID`, which
//  `RootSplitView`'s existing `detail` column already renders via `MacEventDetailView` —
//  no separate detail plumbing needed here.
//

import SwiftUI
import SwiftData

struct MacTodayPlanView: View {
    @Binding var selectedEventID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendarProvider) private var calendarProvider
    @State private var viewModel = TodayPlanViewModel()
    @State private var selectedRecommendationID: String?
    @State private var outcomeRecommendation: PlanningRecommendation?
    @State private var editingRecommendation: PlanningRecommendation?
    @State private var statusMessage: String?

    var body: some View {
        Group {
            if viewModel.isLoading, viewModel.plan == nil {
                ProgressView("Building your plan…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = viewModel.plan {
                if let empty = plan.emptyStateMessage {
                    ContentUnavailableView("All Clear", systemImage: "checkmark.circle", description: Text(empty))
                        .accessibilityIdentifier("macTodayPlanEmptyState")
                } else {
                    splitContent(plan)
                }
            } else {
                ContentUnavailableView("Smart Planning Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Today Plan")
        .toolbar {
            ToolbarItem(placement: .automatic) { refreshButton }
        }
        .task { await refresh() }
        .confirmationDialog(
            "How did it go?", isPresented: Binding(get: { outcomeRecommendation != nil }, set: { if !$0 { outcomeRecommendation = nil } }),
            presenting: outcomeRecommendation
        ) { recommendation in
            outcomeButtons(for: recommendation)
        }
        .sheet(item: $editingRecommendation) { recommendation in
            MacRecommendationEditSheet(recommendation: recommendation, onSave: { date in
                Task { await applyEdit(recommendation, date: date) }
            })
        }
        .alert("Focus", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } }), presenting: statusMessage) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private func splitContent(_ plan: TodayPlan) -> some View {
        HSplitView {
            List(selection: $selectedRecommendationID) {
                Section("Overview") {
                    LabeledContent("Date", value: plan.date.formatted(date: .complete, time: .omitted))
                    LabeledContent("Completed Today", value: "\(plan.completedTodayCount) of \(plan.totalTodayCount)")
                    if let notice = plan.limitedInformationNotice {
                        Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(groupedSections(plan), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { recommendation in
                            MacRecommendationSummaryRow(recommendation: recommendation)
                                .tag(recommendation.id)
                        }
                    }
                }
                if !plan.focusBlocks.isEmpty {
                    Section("Focus Blocks") {
                        ForEach(plan.focusBlocks) { block in
                            MacFocusBlockRow(block: block, onAddToCalendar: { addToCalendar(block) })
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let selected = plan.orderedRecommendations.first(where: { $0.id == selectedRecommendationID }) {
                MacRecommendationDetail(
                    recommendation: selected,
                    onAccept: { Task { await accept(selected) } },
                    onEdit: { editingRecommendation = selected },
                    onDismiss: { dismissRecommendation(selected) },
                    onSnooze: { snoozeRecommendation(selected) },
                    onOpenEvent: { selectedEventID = selected.affectedEventIDs.first },
                    onConfirmOutcome: { outcomeRecommendation = selected }
                )
                .frame(minWidth: 320, maxWidth: .infinity)
            } else {
                ContentUnavailableView("No Recommendation Selected", systemImage: "sparkles", description: Text("Choose one from the list to see the full explanation and actions."))
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
    }

    private struct RecommendationGroup { let title: String; let items: [PlanningRecommendation] }

    private func groupedSections(_ plan: TodayPlan) -> [RecommendationGroup] {
        var groups: [RecommendationGroup] = []
        if let top = plan.mostImportantAction { groups.append(RecommendationGroup(title: "Most Important", items: [top])) }
        if !plan.conflicts.isEmpty { groups.append(RecommendationGroup(title: "Scheduling Conflicts", items: plan.conflicts)) }
        if !plan.urgentItems.isEmpty { groups.append(RecommendationGroup(title: "Needs Attention", items: plan.urgentItems)) }
        if !plan.preparationRisks.isEmpty { groups.append(RecommendationGroup(title: "Preparation Risk", items: plan.preparationRisks)) }
        let shown = Set(groups.flatMap(\.items).map(\.id))
        let remainder = plan.orderedRecommendations.filter { !shown.contains($0.id) }
        if !remainder.isEmpty { groups.append(RecommendationGroup(title: "Also Worth a Look", items: remainder)) }
        return groups
    }

    // MARK: - Actions (identical routing to iOS — see `TodayPlanView`)

    @ViewBuilder
    private func outcomeButtons(for recommendation: PlanningRecommendation) -> some View {
        Button("Completed") { Task { await confirmOutcome(recommendation, as: .complete) } }
        Button("Skipped") { Task { await confirmOutcome(recommendation, as: .skip) } }
        Button("Cancelled", role: .destructive) { Task { await confirmOutcome(recommendation, as: .cancel) } }
        Button("Open Event to Reschedule") { selectedEventID = recommendation.affectedEventIDs.first }
        Button("Not Now", role: .cancel) {}
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
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
            statusMessage = "Added \"\(block.title)\" to Calendar."
        } catch {
            statusMessage = "Couldn't add this to Calendar — Calendar access isn't available."
        }
    }
}

private struct MacRecommendationSummaryRow: View {
    let recommendation: PlanningRecommendation
    var body: some View {
        HStack {
            Image(systemName: recommendation.category.systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(recommendation.title).lineLimit(1)
                Text(recommendation.category.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(recommendation.confidence.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("mac-recommendation-\(recommendation.id)")
    }
}

private struct MacFocusBlockRow: View {
    let block: FocusBlockProposal
    var onAddToCalendar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.title)
            Text("\(block.start.formatted(date: .omitted, time: .shortened)) – \(block.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Button("Add to Calendar", action: onAddToCalendar).buttonStyle(.link)
        }
    }
}

private struct MacRecommendationDetail: View {
    let recommendation: PlanningRecommendation
    var onAccept: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void
    var onSnooze: () -> Void
    var onOpenEvent: () -> Void
    var onConfirmOutcome: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(recommendation.category.displayName, systemImage: recommendation.category.systemImage)
                    .font(.headline)
                Text(recommendation.title).font(.title2.weight(.semibold))
                Text(recommendation.explanation).foregroundStyle(.secondary)
                if !recommendation.contributingFactors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why").font(.subheadline.weight(.semibold))
                        ForEach(recommendation.contributingFactors, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                }
                Text("Confidence: \(recommendation.confidence.rawValue.capitalized)")
                    .font(.callout).foregroundStyle(.secondary)
                if let reason = recommendation.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    ForEach(recommendation.availableActions, id: \.self) { action in
                        button(for: action)
                    }
                }
                .accessibilityIdentifier("macRecommendationActions")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func button(for action: PlanningSuggestedAction) -> some View {
        switch action {
        case .accept: Button("Accept", action: onAccept).keyboardShortcut(.defaultAction)
        case .editBeforeApplying: Button("Edit", action: onEdit)
        case .dismiss: Button("Dismiss", action: onDismiss)
        case .snooze: Button("Snooze", action: onSnooze)
        case .openEvent, .openTask: Button("Open Event", action: onOpenEvent)
        case .confirmOutcome: Button("Confirm Outcome", action: onConfirmOutcome).keyboardShortcut(.defaultAction)
        case .startFocus, .addFocusBlockToCalendar: EmptyView() // Live Activities are iOS-only; Calendar action lives on the focus-block row
        }
    }
}

private struct MacRecommendationEditSheet: View {
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
        VStack(spacing: 16) {
            Text(recommendation.title).font(.headline)
            DatePicker("New Date", selection: $date)
                .accessibilityIdentifier("macRecommendationEditDatePicker")
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { onSave(date); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("macRecommendationEditSaveButton")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
