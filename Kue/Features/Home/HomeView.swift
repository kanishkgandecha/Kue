//
//  HomeView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Screen inventory" / "Navigation" and docs/04-event-types.md
//  "Reconciliation" — Home groups non-archived events into Upcoming / Active / Completed,
//  computed live from EventStatusEngine.derive(for:) per reconciliation rule 1 (always
//  recompute on read) rather than trusting a possibly-stale persisted `status`.
//

import SwiftUI
import SwiftData

private enum HomeSection: String, CaseIterable {
    case upcoming = "Upcoming"
    case active = "Active"
    case completed = "Completed"
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \KueEvent.startDate) private var events: [KueEvent]
    @State private var isAddingEvent = false
    @State private var isShowingTemplates = false
    @State private var addEventType: EventType = .generic
    // Kue 2.0 Phase 2 — search/filter/sort. Default values reproduce Home's original
    // behavior exactly (requirement 7); see `isDefaultQueryState` below.
    @State private var searchText = ""
    @State private var filter: EventListQueryEngine.Filter = .default
    @State private var sortOption: EventListQueryEngine.SortOption = .default
    @State private var isShowingFilterSort = false
    /// Set by `TemplatesView`'s selection, consumed once its sheet has fully dismissed —
    /// see the `onDismiss` below. Presenting the Add sheet immediately (nesting it inside
    /// the still-open Templates sheet instead) leaves Templates covering Home underneath
    /// once Add itself dismisses, so the newly created event isn't reachable/tappable.
    @State private var pendingTemplateEventType: EventType?
    // Kue 2.0 Phase 4 — Import from Calendar (requirement 7/9/12/13). A single `.sheet(item:)`
    // whose *content* switches between the picker and the prefilled form, rather than two
    // separate `.sheet(isPresented:)` modifiers chained together — chaining a second sheet's
    // presentation off the first's `onDismiss` (the `pendingTemplateEventType` pattern above)
    // was observed to leave the second sheet presented but empty for this specific picker →
    // form transition, so this flow instead keeps one continuous sheet presentation and only
    // ever changes what's *inside* it.
    private enum CalendarImportPhase: Identifiable {
        case selecting
        case editing(EventDraft)
        var id: String {
            switch self {
            case .selecting: return "selecting"
            case .editing: return "editing"
            }
        }
    }
    @State private var calendarImportPhase: CalendarImportPhase?
    // Kue 2.0 Phase 5 — Screenshot/OCR import (requirement 1/19/23). Same single-`.sheet(item:)`
    // "one continuous presentation, content switches" shape as `CalendarImportPhase` above, for
    // the same reason. `.editing` carries the ambiguities `NLParsingPipeline` produced
    // alongside the draft — `CalendarImportPipeline` never produces any, so `CalendarImportPhase`
    // above didn't need this, but a screenshot's recognized text is parsed the same way typed
    // NL text is and can be just as ambiguous.
    private enum OCRFlowPhase: Identifiable {
        case scanning
        case editing(EventDraft, [DraftAmbiguity])
        var id: String {
            switch self {
            case .scanning: return "scanning"
            case .editing: return "editing"
            }
        }
    }
    @State private var ocrFlowPhase: OCRFlowPhase?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Kue")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("settingsButton")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isShowingTemplates = true
                        } label: {
                            Label("Templates", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("templatesButton")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isShowingFilterSort = true
                        } label: {
                            Label("Filter & Sort", systemImage: isDefaultFilterAndSort ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityIdentifier("filterSortButton")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            calendarImportPhase = .selecting
                        } label: {
                            Label("Import from Calendar", systemImage: "calendar.badge.plus")
                        }
                        .accessibilityIdentifier("importFromCalendarButton")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            ocrFlowPhase = .scanning
                        } label: {
                            Label("Scan Screenshot", systemImage: "text.viewfinder")
                        }
                        .accessibilityIdentifier("scanScreenshotButton")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            addEventType = .generic
                            isAddingEvent = true
                        } label: {
                            Label("Add Event", systemImage: "plus")
                        }
                        .accessibilityIdentifier("addEventButton")
                    }
                }
                .sheet(isPresented: $isAddingEvent) {
                    EventFormView(mode: .add(initialEventType: addEventType))
                }
                .sheet(isPresented: $isShowingTemplates, onDismiss: presentAddForPendingTemplate) {
                    TemplatesView { type in
                        pendingTemplateEventType = type
                        isShowingTemplates = false
                    }
                }
                // Kue 2.0 Phase 4 — requirement 9/12/13: hands back an already-built, still
                // fully editable `EventDraft`; never creates a `KueEvent` itself. One continuous
                // sheet presentation whose content switches phase — see `CalendarImportPhase`'s
                // own doc comment for why this isn't two chained `.sheet(isPresented:)`
                // modifiers like Templates above.
                .sheet(item: $calendarImportPhase) { phase in
                    switch phase {
                    case .selecting:
                        CalendarImportListView { draft in
                            calendarImportPhase = .editing(draft)
                        }
                    case .editing(let draft):
                        EventFormView(prefilledDraft: draft, ambiguities: [], source: .calendarImport)
                    }
                }
                // Kue 2.0 Phase 5 — requirement 19/23/31: hands back an already-parsed
                // `EventDraft`/ambiguities pair, built by running the user-approved recognized
                // text through the same `NLParsingPipeline` typed NL text uses; never creates a
                // `KueEvent` itself. Same one-continuous-sheet shape as `CalendarImportPhase`.
                .sheet(item: $ocrFlowPhase) { phase in
                    switch phase {
                    case .scanning:
                        OCRImportView { draft, ambiguities in
                            ocrFlowPhase = .editing(draft, ambiguities)
                        }
                    case .editing(let draft, let ambiguities):
                        EventFormView(prefilledDraft: draft, ambiguities: ambiguities, source: .ocr)
                    }
                }
                .sheet(isPresented: $isShowingFilterSort) {
                    EventFilterSortSheet(filter: $filter, sortOption: $sortOption)
                }
                // Requirement 6: the system search control, not a custom search bar — kept on
                // the same List so it plays with Home's existing section-based layout.
                .searchable(text: $searchText, prompt: "Search events")
        }
        .task { EventReconciliation.run(context: modelContext) }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                EventReconciliation.run(context: modelContext)
                // docs/08-notifications.md "Replenishment" — foreground is one of the three
                // triggers that picks anything trimmed by the pending-request cap back up.
                // Passive: never prompts for permission.
                Task {
                    let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
                    await NotificationEngine.reschedule(context: modelContext, intensity: intensity, scheduler: SystemNotificationScheduler.shared)
                }
            case .background:
                // Standard BGAppRefreshTask pattern — schedule the next best-effort
                // opportunity as we leave the foreground.
                SystemBackgroundTaskScheduler.shared.submit(identifier: BackgroundRefreshTask.identifier, earliestBeginDate: nil)
            default:
                break
            }
        }
    }

    private func presentAddForPendingTemplate() {
        guard let type = pendingTemplateEventType else { return }
        pendingTemplateEventType = nil
        addEventType = type
        isAddingEvent = true
    }


    private var visibleEvents: [KueEvent] {
        events.filter { $0.status != .archived }
    }

    private func events(in section: HomeSection) -> [KueEvent] {
        visibleEvents.filter { bucket(for: $0) == section }
    }

    private func bucket(for event: KueEvent) -> HomeSection {
        switch EventStatusEngine.derive(for: event) {
        case .active:
            return .active
        case .completed, .cancelled:
            return .completed
        default:
            return .upcoming
        }
    }

    // MARK: - Kue 2.0 Phase 2 — search/filter/sort

    private var isDefaultFilterAndSort: Bool {
        filter == .default && sortOption == .default
    }

    /// True exactly when Home should show its original three-section layout unmodified —
    /// requirement 7: "preserve the normal Upcoming, Active, and Completed sections when
    /// default filtering and sorting are active."
    private var isDefaultQueryState: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isDefaultFilterAndSort
    }

    private var queryResults: [KueEvent] {
        EventListQueryEngine.query(events: events, searchText: searchText, filter: filter, sort: sortOption)
    }

    /// `events` (not `visibleEvents`) — requirement 8's "empty database" must reflect the
    /// store's actual row count, not just what the current archived scope shows.
    private var emptyReason: EventListQueryEngine.EmptyResultReason {
        EventListQueryEngine.emptyReason(allEvents: events, searchText: searchText, filter: filter)
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            ContentUnavailableView {
                Label("No Events Yet", systemImage: "calendar.badge.clock")
            } description: {
                Text("Add an interview, exam, deadline, or trip to get started.")
            } actions: {
                Button("New Event") {
                    isAddingEvent = true
                }
                Button("Start from a Template") {
                    isShowingTemplates = true
                }
            }
            .accessibilityIdentifier("emptyDatabaseView")
        } else if isDefaultQueryState {
            defaultSectionedList
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

    private var defaultSectionedList: some View {
        List {
            ForEach(HomeSection.allCases, id: \.self) { section in
                let sectionEvents = events(in: section)
                if !sectionEvents.isEmpty {
                    Section(section.rawValue) {
                        ForEach(sectionEvents) { event in
                            NavigationLink {
                                EventDetailView(event: event)
                            } label: {
                                EventRow(event: event)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The flat, sorted view shown whenever search/filter/sort departs from the default —
    /// deliberately not sectioned into Upcoming/Active/Completed, since a non-default sort
    /// (priority, recently modified) has no meaningful relationship to those buckets.
    private var resultsList: some View {
        List {
            Section("Results") {
                ForEach(queryResults) { event in
                    NavigationLink {
                        EventDetailView(event: event)
                    } label: {
                        EventRow(event: event)
                    }
                }
            }
        }
        .accessibilityIdentifier("searchResultsList")
    }
}

#Preview {
    HomeView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}
