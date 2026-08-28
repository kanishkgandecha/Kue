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
    @Environment(\.kueHaptics) private var haptics
    @Query(sort: \KueEvent.startDate) private var events: [KueEvent]
    @State private var isCompletedExpanded = false
    @State private var isLaterExpanded = false

    private var visibleEvents: [KueEvent] {
        events.filter { $0.status != .archived }
    }

    private var timelineSections: [HomeTimelineSection] {
        HomeTimelineGrouping.sections(events: visibleEvents)
    }

    /// Kue 2.0 Phase 10.1 — docs/25 "D.": Awaiting Outcome events belong in their own "Needs
    /// Attention" section, never lumped into Completed alongside events the user actually
    /// confirmed.
    private var needsAttentionEvents: [KueEvent] {
        HomeTimelineGrouping.needsAttentionEvents(events: visibleEvents)
    }

    private var hasTodaySection: Bool {
        timelineSections.contains { $0.kind == .today }
    }

    private var completedEvents: [KueEvent] {
        visibleEvents.filter {
            let status = EventStatusEngine.derive(for: $0)
            return status == .completed || status == .cancelled
        }
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
        .task {
            // Kue 2.0 Phase 11 — docs/26 "M.": launch is one of the sync-trigger points, same
            // reasoning as the reconciliation `.task` immediately above — never blocks first
            // frame (this runs after `body` is already on screen), never polls afterward.
            await SyncCoordinator.shared.sync(context: modelContext)
        }
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
                // Kue 2.0 Phase 11 — docs/26 "M.": scene activation is another documented
                // sync-trigger point (alongside launch, manual Sync Now, outbox changes, and
                // network/account recovery) — never continuous polling.
                Task { await SyncCoordinator.shared.sync(context: modelContext) }
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
        } else if timelineSections.isEmpty && completedEvents.isEmpty && needsAttentionEvents.isEmpty {
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
            // Kue 2.0 Phase 11 — docs/26 "L.": Home shows a small, nonblocking banner only
            // for the two actionable-persistent sync states (account changed, an unresolved
            // conflict) — never a spinner for an ordinary sync pass. Settings remains the
            // detailed source of truth (`syncStatusRow` there covers every other state).
            if SyncCoordinator.shared.status.warrantsHomeBanner {
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label(SyncCoordinator.shared.status.displayText, systemImage: "exclamationmark.icloud")
                            .foregroundStyle(KueColor.warning)
                    }
                    .accessibilityIdentifier("syncHomeBanner")
                }
            }

            // Kue 2.0 Phase 10.1 — docs/25 "D.": "near the top of Home, after any truly active
            // event but before ordinary future sections." Active events only ever appear
            // inside the Today section, so placing this immediately after Today (when Today
            // exists) satisfies both halves at once; when there's no Today section at all,
            // it's simply the first thing shown.
            if !hasTodaySection, !needsAttentionEvents.isEmpty {
                needsAttentionSection
            }

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
                if section.kind == .today, !needsAttentionEvents.isEmpty {
                    needsAttentionSection
                }
            }

            if !completedEvents.isEmpty {
                completedSection
            }
        }
        .accessibilityIdentifier("homeTimelineList")
    }

    private var needsAttentionSection: some View {
        Section {
            ForEach(needsAttentionEvents) { event in
                NeedsAttentionRow(event: event)
            }
        } header: {
            Label("Needs Attention", systemImage: "questionmark.circle")
        } footer: {
            Text("These events have ended without a confirmed outcome.")
        }
        .accessibilityIdentifier("needsAttentionSection")
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

/// Kue 2.0 Phase 10.1 — docs/25 "D." One row in Home's "Needs Attention" section: tapping
/// still navigates to the full outcome flow (Event Detail, docs/25 "E."); the four concise
/// actions here are the same shortcut every other Kue surface already exposes for
/// Complete/Reschedule/Skip/Cancel — no new mutation logic, just faster access without
/// leaving Home. Buttons live inside the `NavigationLink`'s own label — the standard SwiftUI
/// `List` pattern where a distinctly-styled control inside a row's label gets its own tap
/// target, separate from the row's navigation.
private struct NeedsAttentionRow: View {
    @Bindable var event: KueEvent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.kueHaptics) private var haptics
    @State private var isEditingForReschedule = false

    var body: some View {
        NavigationLink {
            EventDetailView(event: event)
        } label: {
            VStack(alignment: .leading, spacing: KueSpacing.sm) {
                EventCard(event: event)
                actionRow
            }
        }
        .sheet(isPresented: $isEditingForReschedule) {
            // docs/25 "E." — "Reschedule opens the existing edit flow ... clears no unrelated
            // data." Same `EventFormView(mode: .edit(event))` every other reschedule path uses.
            EventFormView(mode: .edit(event))
        }
    }

    private var actionRow: some View {
        HStack(spacing: KueSpacing.sm) {
            actionButton("Mark Completed", identifier: "needsAttentionComplete") {
                EventActions.complete(event, context: modelContext)
                haptics.play(.taskCompleted)
            }
            actionButton("Reschedule", identifier: "needsAttentionReschedule") {
                isEditingForReschedule = true
            }
            // Skip is occurrence-aware (docs/17-recurring-events.md) — only offered when this
            // row is actually part of a recurring series, same rule Event Detail already
            // follows.
            if event.seriesID != nil {
                actionButton("Skip", identifier: "needsAttentionSkip") {
                    EventActions.skip(event, context: modelContext)
                }
            }
            // No extra confirmation dialog — matches the existing "Cancel Event" button in
            // Event Detail's own Actions section exactly (reversible via Un-cancel, so only
            // Delete gets a blocking confirmation dialog anywhere in Kue).
            actionButton("Cancel", identifier: "needsAttentionCancel", role: .destructive) {
                EventActions.cancel(event, context: modelContext)
                haptics.play(.destructiveConfirmed)
            }
        }
        .font(KueTypography.footnote)
    }

    private func actionButton(_ title: String, identifier: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("\(identifier)-\(event.id.uuidString)")
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
