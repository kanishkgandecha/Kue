//
//  HomeView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Screen inventory" / "Navigation" — Home is the app's root
//  screen; Add is a sheet, Settings a toolbar-reached destination, no tab bar. Upcoming/
//  Active/Completed sections and event rows land in Phase 2 (Event Management) — this is the
//  empty-state shell only.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Query private var events: [KueEvent]
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
                    }
                }
                .sheet(isPresented: $isAddingEvent) {
                    AddEventView()
                }
        }
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
            }
        } else {
            // Upcoming / Active / Completed sections — docs/09-screens-and-ux.md "Home".
            // Implemented in Phase 2 (Event Management) alongside event creation.
            List(events) { event in
                Text(event.title)
            }
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}
