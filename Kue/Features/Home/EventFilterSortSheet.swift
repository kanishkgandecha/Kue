//
//  EventFilterSortSheet.swift
//  Kue
//
//  Kue 2.0 Phase 2, requirement 6 — "a compact filter/sort sheet rather than permanent
//  dashboard controls." A plain Form bound live to HomeView's own `@State`, dismissed via
//  "Done"; a "Reset" toolbar action returns both bindings to their defaults in one tap. No
//  business logic lives here — every predicate/ordering decision is EventListQueryEngine's
//  (requirement 11: "keep views thin").
//

import SwiftUI

struct EventFilterSortSheet: View {
    @Binding var filter: EventListQueryEngine.Filter
    @Binding var sortOption: EventListQueryEngine.SortOption

    @Environment(\.dismiss) private var dismiss

    /// The lifecycle statuses `EventStatusEngine.derive(for:)` can actually produce (see its
    /// own doc comment on `.preparing`) — offering a status that can never match anything
    /// would be a dead, confusing option, not a real filter.
    private static let filterableStatuses: [EventStatus] = [.upcoming, .tomorrow, .today, .active, .awaitingOutcome, .completed, .cancelled]

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort By") {
                    // Segmented, same style EventDetailView's own tab picker already uses —
                    // renders each option as a directly tappable element (unlike `.inline`,
                    // whose row layout XCUITest can't reliably address by option text alone).
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(EventListQueryEngine.SortOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sortOptionPicker")
                }

                Section("Event Type") {
                    ForEach(EventType.allCases, id: \.self) { type in
                        Toggle(type.displayName, isOn: binding(for: type))
                            .accessibilityIdentifier("filterType-\(type.rawValue)")
                    }
                }

                Section("Status") {
                    ForEach(Self.filterableStatuses, id: \.self) { status in
                        Toggle(statusLabel(status), isOn: binding(for: status))
                            .accessibilityIdentifier("filterStatus-\(status.rawValue)")
                    }
                }

                Section("Archived") {
                    Picker("Archived", selection: $filter.archivedScope) {
                        Text("Current Only").tag(EventListQueryEngine.ArchivedScope.currentOnly)
                        Text("Archived Only").tag(EventListQueryEngine.ArchivedScope.archivedOnly)
                        Text("All").tag(EventListQueryEngine.ArchivedScope.all)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("archivedScopePicker")
                }
            }
            .navigationTitle("Filter & Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        filter = .default
                        sortOption = .default
                    }
                    .accessibilityIdentifier("resetFiltersButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("doneFilterSortButton")
                }
            }
        }
    }

    private func binding(for type: EventType) -> Binding<Bool> {
        Binding(
            get: { filter.eventTypes.contains(type) },
            set: { isOn in
                if isOn { filter.eventTypes.insert(type) } else { filter.eventTypes.remove(type) }
            }
        )
    }

    private func binding(for status: EventStatus) -> Binding<Bool> {
        Binding(
            get: { filter.statuses.contains(status) },
            set: { isOn in
                if isOn { filter.statuses.insert(status) } else { filter.statuses.remove(status) }
            }
        )
    }

    private func statusLabel(_ status: EventStatus) -> String {
        switch status {
        case .draft: return "Draft"
        case .upcoming: return "Upcoming"
        case .preparing: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .active: return "Active"
        case .awaitingOutcome: return "Needs Review"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .archived: return "Archived"
        }
    }
}

#Preview {
    EventFilterSortSheet(filter: .constant(.default), sortOption: .constant(.default))
}
