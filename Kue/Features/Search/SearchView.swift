//
//  SearchView.swift
//  Kue
//
//  Kue 2.0 Phase 7 — dedicated Search destination (bottom navigation). Extracted from
//  `HomeView`'s previous embedded search/filter/sort — same `EventListQueryEngine` (pure,
//  unchanged business logic), same result-list/empty-state identifiers, now living on its own
//  page instead of permanently occupying part of Home. Immediate local results: `queryResults`
//  recomputes synchronously from the live `@Query`, no debounce/network round trip.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Query private var events: [KueEvent]

    @State private var searchText = ""
    @State private var filter: EventListQueryEngine.Filter = .default
    @State private var sortOption: EventListQueryEngine.SortOption = .default
    @State private var isShowingFilterSort = false

    private var isDefaultFilterAndSort: Bool {
        filter == .default && sortOption == .default
    }

    private var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isDefaultFilterAndSort
    }

    private var queryResults: [KueEvent] {
        EventListQueryEngine.query(events: events, searchText: searchText, filter: filter, sort: sortOption)
    }

    private var emptyReason: EventListQueryEngine.EmptyResultReason {
        EventListQueryEngine.emptyReason(allEvents: events, searchText: searchText, filter: filter)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isShowingFilterSort = true
                        } label: {
                            Label("Filter & Sort", systemImage: isDefaultFilterAndSort ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityIdentifier("filterSortButton")
                    }
                }
                .sheet(isPresented: $isShowingFilterSort) {
                    EventFilterSortSheet(filter: $filter, sortOption: $sortOption)
                }
                .searchable(text: $searchText, prompt: "Search title, location, or notes")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasQuery {
            // Requirement: "empty-query state" — distinct from "no results," since nothing's
            // actually been searched for yet.
            ContentUnavailableView {
                Label("Search Your Events", systemImage: "magnifyingglass")
            } description: {
                Text("Find events by title, location, notes, or type — or use Filter & Sort to narrow by status.")
            }
            .accessibilityIdentifier("searchEmptyQueryView")
        } else {
            switch emptyReason {
            case .noResultsForFilters:
                ContentUnavailableView {
                    Label("No Matching Events", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No events match the selected filters.")
                } actions: {
                    Button("Reset Filters") { filter = .default }
                }
                .accessibilityIdentifier("noFilterResultsView")
            case .noResultsForQuery:
                ContentUnavailableView.search(text: searchText)
                    .accessibilityIdentifier("noSearchResultsView")
            case .emptyDatabase, .notEmpty:
                resultsList
            }
        }
    }

    private var resultsList: some View {
        List {
            Section("Results") {
                ForEach(queryResults) { event in
                    NavigationLink {
                        EventDetailView(event: event)
                    } label: {
                        EventCard(event: event)
                    }
                }
            }
        }
        .accessibilityIdentifier("searchResultsList")
    }
}

#Preview("Search — Light") {
    SearchView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}

#Preview("Search — Dark") {
    SearchView()
        .modelContainer(ModelContainerFactory.makeInMemory())
        .preferredColorScheme(.dark)
}
