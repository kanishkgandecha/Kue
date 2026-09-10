//
//  EventListComponents.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — shared list-row rendering + the Home/Filtered/Search list surfaces.
//  Every ordering/grouping/status decision is read from `HomeTimelineGrouping`/
//  `EventStatusEngine`/`EventListQueryEngine` (Shared/) — no second derivation lives here.
//

import SwiftUI
import SwiftData

/// One selectable row — title, type, status pill, and a compact date/countdown line. No task
/// titles or notes shown here (list density, not a miniature detail view).
struct MacEventRow: View {
    let event: KueEvent

    private var status: EventStatus { EventStatusEngine.derive(for: event) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Untitled" : event.title)
                    .lineLimit(1)
                Text("\(event.eventType.displayName) · \(dateLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(statusLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(event.id)
    }

    private var dateLine: String {
        event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)
    }

    private var statusLabel: String {
        switch status {
        case .draft: return "Draft"
        case .upcoming: return "Upcoming"
        case .preparing: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .active: return "Active"
        case .awaitingOutcome: return "Needs Review"
        case .completed: return "Completed"
        case .cancelled: return event.isSkipped ? "Skipped" : "Cancelled"
        case .archived: return "Archived"
        }
    }

    private var iconName: String {
        switch event.eventType {
        case .generic: return "calendar"
        case .deadline: return "flag"
        case .exam: return "graduationcap"
        case .interview: return "person.crop.circle"
        case .trip: return "airplane"
        }
    }

    private var iconColor: Color {
        switch status {
        case .cancelled, .archived: return .secondary
        case .awaitingOutcome: return .orange
        case .active, .today: return .red
        default: return .accentColor
        }
    }
}

/// Home — the full date-sectioned timeline, exactly mirroring the iPhone app's own grouping
/// policy (`HomeTimelineGrouping`), plus the Needs Attention section on top.
struct MacHomeListView: View {
    let events: [KueEvent]
    @Binding var selectedEventID: UUID?
    var onNewEvent: () -> Void

    private var needsAttention: [KueEvent] { HomeTimelineGrouping.needsAttentionEvents(events: events) }
    private var sections: [HomeTimelineSection] { HomeTimelineGrouping.sections(events: events) }

    var body: some View {
        List(selection: $selectedEventID) {
            if !needsAttention.isEmpty {
                Section("Needs Attention") {
                    ForEach(needsAttention) { MacEventRow(event: $0) }
                }
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.events) { MacEventRow(event: $0) }
                }
            }
            if needsAttention.isEmpty && sections.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "calendar.badge.plus", description: Text("Create your first event to get started."))
            }
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem {
                Button("New Event", systemImage: "plus", action: onNewEvent)
                    .accessibilityIdentifier("newEventButton")
            }
        }
    }
}

/// Today / Upcoming / Needs Review / Completed — a flat, already-filtered list; no re-grouping.
struct MacFilteredListView: View {
    let title: String
    let events: [KueEvent]
    @Binding var selectedEventID: UUID?

    var body: some View {
        List(selection: $selectedEventID) {
            ForEach(events) { MacEventRow(event: $0) }
        }
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "tray", description: Text("No events currently match “\(title).”"))
            }
        }
        .navigationTitle(title)
    }
}

/// Search — the dedicated sidebar destination, reusing `EventListQueryEngine` verbatim (same
/// engine `HomeView`'s `.searchable` on iOS reads) rather than a second normalization/filter
/// implementation.
struct MacSearchListView: View {
    let events: [KueEvent]
    @Binding var selectedEventID: UUID?

    @State private var searchText = ""
    @State private var filter = EventListQueryEngine.Filter.default
    @State private var sort = EventListQueryEngine.SortOption.default

    private var results: [KueEvent] {
        EventListQueryEngine.query(events: events, searchText: searchText, filter: filter, sort: sort)
    }

    private var emptyReason: EventListQueryEngine.EmptyResultReason {
        EventListQueryEngine.emptyReason(allEvents: events, searchText: searchText, filter: filter)
    }

    var body: some View {
        List(selection: $selectedEventID) {
            ForEach(results) { MacEventRow(event: $0) }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(emptyStateTitle, systemImage: "magnifyingglass", description: Text(emptyStateDescription))
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search events")
        .toolbar {
            ToolbarItem {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $sort) {
                        ForEach(EventListQueryEngine.SortOption.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            }
            ToolbarItem {
                Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(EventType.allCases, id: \.self) { type in
                        Button {
                            toggle(type)
                        } label: {
                            Label(type.displayName, systemImage: filter.eventTypes.contains(type) ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button("Clear Filters") { filter = .default }
                }
            }
        }
        .navigationTitle("Search")
    }

    private func toggle(_ type: EventType) {
        if filter.eventTypes.contains(type) {
            filter.eventTypes.remove(type)
        } else {
            filter.eventTypes.insert(type)
        }
    }

    private var emptyStateTitle: String {
        switch emptyReason {
        case .emptyDatabase: return "No Events Yet"
        case .noResultsForQuery: return "No Matches"
        case .noResultsForFilters: return "No Matches"
        case .notEmpty: return ""
        }
    }

    private var emptyStateDescription: String {
        switch emptyReason {
        case .emptyDatabase: return "Create your first event to get started."
        case .noResultsForQuery: return "No events match “\(searchText).”"
        case .noResultsForFilters: return "No events match the selected filters."
        case .notEmpty: return ""
        }
    }
}
