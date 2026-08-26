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
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isAddingEvent = true
                        } label: {
                            Label("Add Event", systemImage: "plus")
                        }
                        .accessibilityIdentifier("addEventButton")
                    }
                }
                .sheet(isPresented: $isAddingEvent) {
                    EventFormView(mode: .add)
                }
        }
        .task { EventStatusEngine.sweep(context: modelContext) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                EventStatusEngine.sweep(context: modelContext)
            }
        }
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

    @ViewBuilder
    private var content: some View {
        if visibleEvents.isEmpty {
            ContentUnavailableView {
                Label("No Events Yet", systemImage: "calendar.badge.clock")
            } description: {
                Text("Add an interview, exam, deadline, or trip to get started.")
            } actions: {
                Button("New Event") {
                    isAddingEvent = true
                }
            }
        } else {
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
    }
}

#Preview {
    HomeView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}
