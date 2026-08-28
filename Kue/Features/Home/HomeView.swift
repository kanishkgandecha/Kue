//
//  HomeView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Screen inventory" / "Navigation" and docs/04-event-types.md
//  "Reconciliation" — statuses are always computed live via `EventStatusEngine.derive(for:)`
//  per reconciliation rule 1 (never trust a possibly-stale persisted `status`).
//
//  Kue 2.0 Phase 7 — Design System / Liquid Glass redesign, second pass
//  (docs/21-design-system.md "Home — date-sectioned timeline"). Home is now the app's
//  centered-wordmark timeline root inside `RootTabView`'s five-destination bottom navigation:
//   - Search, Add, Templates, and Settings all moved to their own bottom-navigation
//     destinations (`SearchView`/`AddHubView`/`TemplatesView`/`SettingsView`) — Home's own
//     toolbar carries nothing anymore, so `KueWordmark` renders as a true full-width-centered
//     `.principal` toolbar item with nothing competing against it.
//   - Rows are grouped by calendar date (Today / Tomorrow / specific dates / a restrained
//     trailing "Later" group) via `HomeTimelineGrouping` — a pure, timezone-pinned,
//     deterministic grouping of the exact same `EventStatusEngine`-derived events the old
//     Upcoming/Active/Completed sections showed, not a new business rule.
//   - Completed/cancelled events live in their own compact, collapsible section below the
//     timeline — never proliferating date sections, never duplicated between the two.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \KueEvent.startDate) private var events: [KueEvent]
    @State private var isCompletedExpanded = false
    @State private var isLaterExpanded = false

    private var visibleEvents: [KueEvent] {
        events.filter { $0.status != .archived }
    }

    private var timelineSections: [HomeTimelineSection] {
        HomeTimelineGrouping.sections(events: visibleEvents)
    }

    private var completedEvents: [KueEvent] {
        visibleEvents.filter { !HomeTimelineGrouping.timelineEligible($0) }
    }

    var body: some View {
        NavigationStack {
            content
                // Requirement: no additional "Home" navigation title — `.principal` is the
                // *only* toolbar content, so the system centers it against the full screen
                // width, not just whatever space happens to be left between other items.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        KueWordmark()
                    }
                }
        }
        .task { await EventReconciliation.run(context: modelContext) }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await EventReconciliation.run(context: modelContext) }
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

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            ContentUnavailableView {
                Label("No Events Yet", systemImage: "calendar.badge.clock")
            } description: {
                Text("Add an interview, exam, deadline, or trip to get started.")
            }
            .accessibilityIdentifier("emptyDatabaseView")
        } else if timelineSections.isEmpty && completedEvents.isEmpty {
            // Every visible event is archived — a real, if rare, state distinct from "no
            // events at all."
            ContentUnavailableView {
                Label("Nothing To Show", systemImage: "calendar.badge.clock")
            } description: {
                Text("Everything here has been archived.")
            }
        } else {
            timeline
        }
    }

    /// Requirement: "Do not show a full-page empty state merely because Today has no events
    /// when future events exist" — `timelineSections` already only ever contains sections
    /// that actually have events (`HomeTimelineGrouping` never emits an empty one), so this
    /// list simply starts at whichever section is soonest; no "Today" placeholder row needed.
    private var timeline: some View {
        List {
            ForEach(Array(timelineSections.enumerated()), id: \.element.id) { index, section in
                if section.kind == .later {
                    laterSection(section)
                } else {
                    Section(section.title) {
                        ForEach(section.events) { event in
                            NavigationLink {
                                EventDetailView(event: event)
                            } label: {
                                EventCard(event: event)
                            }
                        }
                    }
                }
            }

            if !completedEvents.isEmpty {
                completedSection
            }
        }
        .accessibilityIdentifier("homeTimelineList")
    }

    /// Requirement: distant events "must remain discoverable and correctly ordered" —
    /// collapsed by default (keeps the common case calm) but always present and expandable,
    /// never hidden behind a separate screen.
    private func laterSection(_ section: HomeTimelineSection) -> some View {
        Section {
            DisclosureGroup("Later (\(section.events.count))", isExpanded: $isLaterExpanded) {
                ForEach(section.events) { event in
                    NavigationLink {
                        EventDetailView(event: event)
                    } label: {
                        EventCard(event: event)
                    }
                }
            }
            .accessibilityIdentifier("laterSectionDisclosure")
        }
    }

    /// Requirement: "a compact collapsible Completed section for Today, plus History access"
    /// — collapsed by default so a long history never dominates the timeline; every completed
    /// event is still reachable here (and via Search, which includes completed/archived scope
    /// per its own filter), never duplicated into a date section above.
    private var completedSection: some View {
        Section {
            DisclosureGroup("Completed (\(completedEvents.count))", isExpanded: $isCompletedExpanded) {
                ForEach(completedEvents) { event in
                    NavigationLink {
                        EventDetailView(event: event)
                    } label: {
                        EventCard(event: event)
                    }
                }
            }
            .accessibilityIdentifier("completedSectionDisclosure")
        }
    }
}

#Preview("Home — Light") {
    RootTabView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}

#Preview("Home — Dark") {
    RootTabView()
        .modelContainer(ModelContainerFactory.makeInMemory())
        .preferredColorScheme(.dark)
}

#Preview("Home — Large Dynamic Type") {
    RootTabView()
        .modelContainer(ModelContainerFactory.makeInMemory())
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
