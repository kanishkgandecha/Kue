//
//  RootSplitView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — the native macOS shell: a persistent sidebar `NavigationSplitView`, not
//  the iPhone's bottom tab bar (`Kue/App/RootTabView.swift`, iOS-only, not reused here). The
//  selected sidebar destination stays stable while an event detail opens/closes (requirement:
//  "should remain stable") because it lives in this view's own `@State`, entirely independent
//  of `selectedEvent`.
//

import SwiftUI
import SwiftData

enum MacSidebarDestination: String, CaseIterable, Identifiable {
    case home, plan, today, upcoming, needsReview, search, templates, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .plan: return "Plan"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .needsReview: return "Needs Review"
        case .search: return "Search"
        case .templates: return "Templates"
        case .completed: return "Completed"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .plan: return "sparkles"
        case .today: return "sun.max"
        case .upcoming: return "calendar"
        case .needsReview: return "exclamationmark.circle"
        case .search: return "magnifyingglass"
        case .templates: return "doc.on.doc"
        case .completed: return "checkmark.circle"
        }
    }
}

struct RootSplitView: View {
    @Bindable var appState: MacAppState

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KueEvent.startDate) private var allEvents: [KueEvent]

    @State private var selectedDestination: MacSidebarDestination = .home
    @State private var selectedEventID: UUID?
    @State private var isPresentingNewEvent = false
    @State private var newEventInitialType: EventType?
    @State private var newEventDraft: EventDraft?
    @State private var isPresentingOnboarding = OnboardingPreference.shouldPresent
    @State private var isImportingFromCalendar = false

    private var selectedEvent: KueEvent? {
        guard let selectedEventID else { return nil }
        return allEvents.first { $0.id == selectedEventID }
    }

    var body: some View {
        NavigationSplitView {
            List(MacSidebarDestination.allCases, selection: $selectedDestination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .accessibilityIdentifier("sidebar-\(destination.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
            .navigationTitle("Kue")
        } content: {
            destinationContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let selectedEvent {
                MacEventDetailView(event: selectedEvent, onDeleted: { selectedEventID = nil })
            } else {
                ContentUnavailableView("No Event Selected", systemImage: "calendar", description: Text("Choose an event from the list."))
            }
        }
        .sheet(isPresented: $isPresentingOnboarding) {
            MacOnboardingView(onDismiss: { isPresentingOnboarding = false })
        }
        .sheet(isPresented: $isPresentingNewEvent) {
            MacEventEditorView(mode: editorMode) { savedID in
                selectedEventID = savedID
                selectedDestination = .home
            }
        }
        .sheet(isPresented: $isImportingFromCalendar) {
            MacCalendarImportListView { draft in
                // Dismiss this sheet first, then present the review editor on top — the same
                // sequencing `MacCalendarImportListView`'s own header documents, avoiding a
                // nested-sheet presentation race.
                isImportingFromCalendar = false
                newEventDraft = draft
                isPresentingNewEvent = true
            }
        }
        .onChange(of: selectedDestination) { _, _ in
            // Requirement: destination switching shouldn't strand a detail selection from a
            // now-hidden list — a fresh destination starts with nothing selected.
            selectedEventID = nil
        }
        .onChange(of: selectedEventID) { _, newValue in
            appState.selectedEventID = newValue
        }
        .onChange(of: appState.pendingCommand) { _, command in
            guard let command else { return }
            handle(command)
            appState.pendingCommand = nil
        }
    }

    private func handle(_ command: MacAppState.PendingCommand) {
        switch command {
        case .newEvent: presentNewEvent()
        case .search: selectedDestination = .search
        case .showHome: selectedDestination = .home
        case .showToday: selectedDestination = .today
        case .showUpcoming: selectedDestination = .upcoming
        case .showNeedsReview: selectedDestination = .needsReview
        case .deleteSelectedEvent:
            // A recurring occurrence needs an explicit This Event / This and Future choice —
            // never guessed. That confirmation lives on the Detail view's own Delete button
            // (already visible, since this event is selected); the global shortcut only
            // acts directly on a plain, non-recurring event.
            if let event = selectedEvent, event.seriesID == nil {
                EventActions.delete(event, context: modelContext)
                selectedEventID = nil
            }
        case .exportBackup, .restoreBackup:
            break // Handled by opening Settings ▸ Backup (see `KueMacCommands`).
        case .showOnboarding:
            isPresentingOnboarding = true
        case .importFromCalendar:
            isImportingFromCalendar = true
        }
    }

    private var editorMode: MacEventEditorMode {
        if let newEventDraft {
            return .addFromDraft(newEventDraft, source: .calendarImport)
        }
        return .add(initialEventType: newEventInitialType ?? .generic)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch selectedDestination {
        case .home:
            MacHomeListView(events: allEvents, selectedEventID: $selectedEventID, onNewEvent: presentNewEvent)
        case .plan:
            MacTodayPlanView(selectedEventID: $selectedEventID)
        case .today:
            MacFilteredListView(
                title: "Today",
                events: allEvents.filter { EventStatusEngine.derive(for: $0) == .today || EventStatusEngine.derive(for: $0) == .active },
                selectedEventID: $selectedEventID
            )
        case .upcoming:
            MacFilteredListView(
                title: "Upcoming",
                events: allEvents.filter { HomeTimelineGrouping.timelineEligible($0) }.sorted { $0.startDate < $1.startDate },
                selectedEventID: $selectedEventID
            )
        case .needsReview:
            MacFilteredListView(
                title: "Needs Review",
                events: HomeTimelineGrouping.needsAttentionEvents(events: allEvents),
                selectedEventID: $selectedEventID
            )
        case .search:
            MacSearchListView(events: allEvents, selectedEventID: $selectedEventID)
        case .templates:
            MacTemplatesView(onStart: { eventType in
                newEventInitialType = eventType
                newEventDraft = nil
                isPresentingNewEvent = true
            })
        case .completed:
            MacFilteredListView(
                title: "Completed",
                events: EventListQueryEngine.query(
                    events: allEvents, searchText: "",
                    filter: EventListQueryEngine.Filter(statuses: [.completed]),
                    sort: .recentlyModified
                ),
                selectedEventID: $selectedEventID
            )
        }
    }

    private func presentNewEvent() {
        newEventInitialType = nil
        newEventDraft = nil
        isPresentingNewEvent = true
    }
}
