//
//  LockScreenEventSelectionView.swift
//  Kue
//
//  Post-Phase-12 fix — the focused Lock Screen Event selection page, reachable from the
//  widget's own empty/unavailable-state deep link (`kue://widgets/lock-screen/select`) and
//  Settings → Widgets → Lock Screen Event. Deliberately not a navigation into `EventFormView`/
//  `EventDetailView` — this only ever writes `LockScreenEventSelection`, never event content.
//
//  Reuses `EventListQueryEngine.query` (Phase 2's own search/sort engine) for the searchable
//  list and `WidgetContentService.isEligibleForLockScreenSelection` for what's offered — no
//  parallel query/eligibility logic invented here.
//

import SwiftUI
import SwiftData

struct LockScreenEventSelectionView: View {
    @Query private var events: [KueEvent]
    @Environment(\.dismiss) private var dismiss
    var widgetReloader: WidgetReloading = SystemWidgetReloader.shared

    @State private var searchText = ""
    @State private var isConfirmingClear = false

    private var selectedEventID: UUID? { LockScreenEventSelection.current }

    private var selectedEvent: KueEvent? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    private var eligibleEvents: [KueEvent] {
        let eligible = events.filter { WidgetContentService.isEligibleForLockScreenSelection($0) }
        return EventListQueryEngine.query(events: eligible, searchText: searchText, filter: .default, sort: .default)
    }

    var body: some View {
        List {
            Section {
                summaryRow
                if selectedEventID != nil {
                    Button("Clear Selection", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .accessibilityIdentifier("clearLockScreenSelectionButton")
                }
            } footer: {
                // Both explanations the feature's own spec requires, together — this is the
                // one place either is said.
                Text("This selection applies to all of Kue's Lock Screen widgets — placing more than one still shows the same event. If the selected event becomes unavailable, the widget will not automatically switch to another event.")
            }

            Section(selectedEventID == nil ? "Choose an Event" : "Change Event") {
                if eligibleEvents.isEmpty {
                    emptyState
                } else {
                    ForEach(eligibleEvents) { event in
                        Button {
                            select(event)
                        } label: {
                            eventRow(event)
                        }
                        .accessibilityIdentifier("lockScreenEventOption-\(event.id.uuidString)")
                    }
                }
            }
        }
        // `.navigationBarDrawer(displayMode: .always)` — this view is reached both pushed
        // (Settings → Widgets) and sheet-presented (the widget's own empty-state deep link);
        // `.automatic` placement was observed to omit the search field entirely in the pushed
        // case, so the field is forced always-visible rather than left to a placement that
        // wasn't reliably rendering it.
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search events")
        .navigationTitle("Lock Screen Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("lockScreenSelectionDoneButton")
            }
        }
        .confirmationDialog(
            "Clear the Lock Screen selection? The widget will show \"Select Event\" until you choose again.",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Selection", role: .destructive) { clear() }
        }
    }

    @ViewBuilder
    private var summaryRow: some View {
        if let selectedEvent {
            LabeledContent {
                Text(selectedEvent.title)
            } label: {
                Text("Currently Selected")
            }
            .accessibilityIdentifier("lockScreenCurrentSelectionLabel")
            .accessibilityLabel("Currently selected: \(selectedEvent.title)")
        } else if selectedEventID != nil {
            // A UUID is stored but doesn't resolve to any event — deleted since it was chosen.
            Label("The selected event is no longer available.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("lockScreenSelectionUnavailableLabel")
        } else {
            Label("No event selected", systemImage: "calendar.badge.plus")
                .foregroundStyle(KueColor.secondaryText)
                .accessibilityIdentifier("lockScreenNoSelectionLabel")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "No Eligible Events" : "No Matching Events",
            systemImage: "calendar.badge.exclamationmark",
            description: Text(searchText.isEmpty
                ? "Events that are cancelled, skipped, completed, or archived can't be chosen here."
                : "Try a different search.")
        )
        .accessibilityIdentifier("lockScreenSelectionEmptyState")
    }

    private func eventRow(_ event: KueEvent) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .foregroundStyle(KueColor.primaryText)
                Text("\(event.eventType.displayName) · \(SpotlightEventPayloadBuilder.statusLabel(for: EventStatusEngine.derive(for: event)))")
                    .font(.caption)
                    .foregroundStyle(KueColor.secondaryText)
            }
            Spacer()
            if event.id == selectedEventID {
                Image(systemName: "checkmark")
                    .foregroundStyle(KueColor.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func select(_ event: KueEvent) {
        LockScreenEventSelection.select(event.id, reloader: widgetReloader)
        dismiss()
    }

    private func clear() {
        LockScreenEventSelection.clear(reloader: widgetReloader)
    }
}

#Preview {
    NavigationStack {
        LockScreenEventSelectionView()
    }
    .modelContainer(ModelContainerFactory.makeInMemory())
}
