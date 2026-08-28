//
//  RootTabView.swift
//  Kue
//
//  Kue 2.0 Phase 7 — the five-destination Liquid Glass bottom navigation. `TabView(selection:)`
//  built from the modern value-based `Tab(...)` API gets the system's own native Liquid Glass
//  tab bar (this deployment target, iOS 26.5) automatically — the selected destination's pill,
//  its Reduce Motion/Reduce Transparency/Increased Contrast adaptation, VoiceOver's
//  name/selected-state/position announcement, and safe-area/keyboard handling are all system
//  behavior, not reimplemented here (requirement: "do not imitate Liquid Glass with arbitrary
//  blur/gradient/shadow/overlay stacks when native APIs provide the intended effect").
//
//  Each destination gets its own `NavigationStack` (`independent navigation stacks... where
//  practical`) so pushing into Event Detail from Search, or opening Templates, never disturbs
//  Home's own stack — switching tabs mid-flow in Add/Search/Templates only ever *hides* that
//  stack, it never tears down or corrupts an in-progress creation/editing sheet (SwiftUI keeps
//  each `Tab`'s content alive across selection changes by construction).
//
//  Selection lives in plain `@State` (`Destination`, a presentation-only enum) — never written
//  to SwiftData (requirement: "do not store the selected tab in SwiftData," "do not add a new
//  schema version for navigation state").
//

import SwiftUI
import SwiftData

enum RootDestination: Hashable {
    case home
    case search
    case add
    case templates
    case settings
}

struct RootTabView: View {
    /// Kue 2.0 Phase 8+ (widgets/notifications/Calendar/Live Activities) deep-links land here
    /// — selecting the destination whose stack the target belongs to without discarding the
    /// other four destinations' own navigation state (requirement 22).
    @State private var selection: RootDestination = .home

    /// Kue 2.0 Phase 8 — see docs/22-expanded-and-dedicated-widgets.md "E." Presented as a
    /// sheet over whichever tab is active (not pushed onto Home's own stack) so a widget tap
    /// never disturbs Home's in-progress navigation state, matching the "independent
    /// navigation stacks" principle above.
    @State private var deepLinkedEvent: KueEvent?
    @State private var isShowingDedicatedCountdownHelp = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: RootDestination.home) {
                HomeView()
            }
            .accessibilityIdentifier("tab-home")

            Tab("Search", systemImage: "magnifyingglass", value: RootDestination.search) {
                SearchView()
            }
            .accessibilityIdentifier("tab-search")

            // Requirement: "Add must be the central destination" — its literal position in
            // this 5-tab list (3rd of 5) is what actually guarantees that, natively, without
            // any custom layout math.
            Tab("Add", systemImage: "plus", value: RootDestination.add) {
                AddHubView()
            }
            .accessibilityIdentifier("tab-add")

            Tab("Templates", systemImage: "square.grid.2x2", value: RootDestination.templates) {
                NavigationStack {
                    TemplatesView { type in
                        // Templates' own selection used to hand off to Home's Add sheet via a
                        // "set a flag, present after dismiss" dance (nested-sheet bug
                        // avoidance — see the original `HomeView.presentAddForPendingTemplate`
                        // this replaces). As this tab's own root, it can push the prefilled
                        // form directly instead.
                        pendingTemplateEventType = type
                    }
                    .navigationDestination(item: $pendingTemplateEventType) { type in
                        EventFormView(mode: .add(initialEventType: type))
                    }
                }
            }
            .accessibilityIdentifier("tab-templates")

            Tab("Settings", systemImage: "gearshape", value: RootDestination.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
            .accessibilityIdentifier("tab-settings")
        }
        .accessibilityIdentifier("rootTabBar")
        .onOpenURL { url in
            guard let destination = KueDeepLink.parse(url) else { return }
            switch destination {
            case .event(let id):
                // Requirement: "validate deep links and handle missing identifiers safely" —
                // a stale/deleted id just does nothing rather than presenting an empty sheet.
                if let event = try? modelContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first {
                    deepLinkedEvent = event
                }
            case .dedicatedCountdownHelp:
                isShowingDedicatedCountdownHelp = true
            }
        }
        .sheet(item: $deepLinkedEvent) { event in
            NavigationStack {
                EventDetailView(event: event)
            }
        }
        .sheet(isPresented: $isShowingDedicatedCountdownHelp) {
            DedicatedCountdownHelpView()
        }
    }

    @State private var pendingTemplateEventType: EventType?
}

#Preview("Root Tab Bar — Light") {
    RootTabView()
        .modelContainer(ModelContainerFactory.makeInMemory())
}

#Preview("Root Tab Bar — Dark") {
    RootTabView()
        .modelContainer(ModelContainerFactory.makeInMemory())
        .preferredColorScheme(.dark)
}
