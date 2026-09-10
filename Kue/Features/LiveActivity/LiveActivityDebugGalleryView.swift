//
//  LiveActivityDebugGalleryView.swift
//  Kue
//
//  Kue 3.0 Phase 2 (docs/30-kue-3-live-activities-and-dynamic-island.md "Debug validation
//  gallery") — a developer-only surface for inspecting every Live Activity/Dynamic Island
//  fixture on a physical iPhone, since neither Xcode Previews nor the Simulator can faithfully
//  render real Lock Screen materials/vibrancy or genuine Dynamic Island hardware (docs/23 "L.").
//  The whole file is wrapped in `#if DEBUG` — not merely hidden behind a runtime flag, it does
//  not exist in a Release build at all — and reachable only from `SettingsView`'s own matching
//  `#if DEBUG` section.
//
//  Real, disclosed ActivityKit limitation (documented rather than worked around unsafely):
//  there is no sandboxed "test" Activity namespace, so a fixture started here runs through the
//  exact same `LiveActivityManaging` seam (`SystemLiveActivityManager` in a normal run) the
//  real Focus feature uses — the only way to see genuine system rendering. Starting a fixture
//  therefore **ends whatever real Live Activity is currently focused** (the same
//  one-Kue-activity-at-a-time system slot `LiveActivityFocusCoordinator` already enforces).
//  This view says so up front rather than silently interrupting a real focus session, and
//  cleans up whatever fixture it started (`endRunningFixture()`, also called from
//  `.onDisappear`).
//
//  Never touches SwiftData: every fixture is a plain in-memory `KueEvent`/`KueTask` built
//  directly via their own `init` — never `context.insert`, never `try context.save()`, no
//  `@Environment(\.modelContext)` even exists in this file. The production event store is
//  never opened here.
//

#if DEBUG
import SwiftUI

struct LiveActivityDebugGalleryView: View {
    @Environment(\.liveActivityManager) private var manager
    @State private var runningFixtureLabel: String?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Label("Developer tool — Debug builds only", systemImage: "hammer.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Starting a fixture ends whatever real Live Activity is currently focused — ActivityKit allows only one Kue-owned activity at a time and has no isolated test namespace. This never opens or writes the real event store; every fixture is an in-memory value, never inserted anywhere.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let runningFixtureLabel {
                Section("Currently running") {
                    Text(runningFixtureLabel)
                    Button("End Fixture Activity", role: .destructive) {
                        Task { await endRunningFixture() }
                    }
                }
            }

            if let statusMessage {
                Section { Text(statusMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Lifecycle states") {
                fixtureRow("Upcoming (10 days, snoozable task)", action: { await self.start(label: $0, event: Self.upcoming()) })
                fixtureRow("Preparing (2 days, one task)", action: { await self.start(label: $0, event: Self.preparing()) })
                fixtureRow("Tomorrow", action: { await self.start(label: $0, event: Self.tomorrow()) })
                fixtureRow("Today · starting now", action: { await self.start(label: $0, event: Self.startingNow()) })
                fixtureRow("Today · in progress", action: { await self.start(label: $0, event: Self.inProgress()) })
                fixtureRow("Needs Review", action: { await self.start(label: $0, event: Self.needsReview()) })
                fixtureRow("Completed", action: { await self.start(label: $0, event: Self.completedFixture()) })
                fixtureRow("Cancelled", action: { await self.start(label: $0, event: Self.cancelledFixture()) })
                fixtureRow("Skipped", action: { await self.start(label: $0, event: Self.skippedFixture()) })
                fixtureRow("Archived", action: { await self.start(label: $0, event: Self.archivedFixture()) })
                fixtureRow("Missing / store failure", action: { await self.startThenMarkUnavailable(label: $0) })
            }

            Section("Edge cases") {
                fixtureRow("Very long title", action: { await self.start(label: $0, event: Self.longTitleFixture()) })
                fixtureRow("No tasks", action: { await self.start(label: $0, event: Self.noTasksFixture()) })
                fixtureRow("Many tasks (6, 2 done)", action: { await self.start(label: $0, event: Self.manyTasksFixture()) })
                fixtureRow("Three-digit day countdown (128 days)", action: { await self.start(label: $0, event: Self.threeDigitCountdownFixture()) })
                fixtureRow("Privacy hidden (title + task)", action: { await self.startPrivacyHidden(label: $0) })
            }
        }
        .navigationTitle("Live Activity Gallery")
        .onDisappear {
            Task { await endRunningFixture() }
        }
    }

    // MARK: - Rows

    private func fixtureRow(_ label: String, action: @escaping (String) async -> Void) -> some View {
        Button(label) {
            Task { await action(label) }
        }
    }

    // MARK: - Actions

    private func start(label: String, event: KueEvent) async {
        await endRunningFixture()
        switch await manager.start(for: event, now: .now) {
        case .started:
            runningFixtureLabel = label
            statusMessage = nil
        case .failed(let reason):
            statusMessage = "Could not start (\(reason)) — Live Activities may be off in Settings."
        }
    }

    /// The "Missing / store failure" fixture: `.unavailable` is only reachable through
    /// `reconcileFocusedActivity(with: nil, now:)` (the real path a deleted focused event
    /// takes — docs/23 "G."), never through `start(for:)`, which always needs a real event to
    /// build a `.tracking` state from. Starts a throwaway fixture first, then reconciles it
    /// against `nil` — exactly what a genuinely deleted event triggers, with no SwiftData
    /// involved on either side.
    private func startThenMarkUnavailable(label: String) async {
        await start(label: "Missing / store failure (starting…)", event: Self.upcoming())
        await manager.reconcileFocusedActivity(with: nil, now: .now)
        runningFixtureLabel = label
    }

    /// The only fixture that needs the *real* privacy-redaction code path exercised end to
    /// end, not faked — `LiveActivityStateBuilder.contentState` only redacts via
    /// `LiveActivityPrivacyPreference.current`, which `start(for:)` always reads at call time.
    /// Saves the real preference, flips both toggles off just long enough to start the
    /// fixture (so the resulting `ContentState` is genuinely redacted), then restores whatever
    /// the user actually had set — this is the same App Group `UserDefaults` Settings' own
    /// privacy toggles already read/write, never a new store, and never left altered.
    private func startPrivacyHidden(label: String) async {
        let original = LiveActivityPrivacyPreference.current
        LiveActivityPrivacyPreference.setShowTitle(false)
        LiveActivityPrivacyPreference.setShowNextTask(false)
        defer {
            LiveActivityPrivacyPreference.setShowTitle(original.showTitle)
            LiveActivityPrivacyPreference.setShowNextTask(original.showNextTask)
        }
        await start(label: label, event: Self.preparing())
    }

    private func endRunningFixture() async {
        guard let eventID = await manager.focusedEventID() else {
            runningFixtureLabel = nil
            return
        }
        await manager.end(eventID: eventID, dismissalPolicy: .immediate)
        runningFixtureLabel = nil
    }

    // MARK: - Fixtures (in-memory only — never inserted into any ModelContext)

    private static func makeEvent(
        title: String = "Fixture Event",
        eventType: EventType = .generic,
        startDate: Date,
        estimatedDurationMinutes: Int = 60,
        endDate: Date? = nil,
        status: EventStatus = .upcoming,
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false,
        tasks: [KueTask] = []
    ) -> KueEvent {
        KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: estimatedDurationMinutes,
            source: .manual,
            status: status,
            isCancelled: isCancelled,
            isManuallyCompleted: isManuallyCompleted,
            isSkipped: isSkipped,
            tasks: tasks
        )
    }

    private static func makeTask(title: String, dueDate: Date, isCompleted: Bool = false, sortOrder: Int = 0) -> KueTask {
        KueTask(title: title, dueDate: dueDate, isCompleted: isCompleted, offsetLabel: "Fixture task", sortOrder: sortOrder)
    }

    private static func upcoming() -> KueEvent {
        let start = Date.now.addingTimeInterval(10 * 86_400)
        return makeEvent(title: "Upcoming Fixture", eventType: .exam, startDate: start, tasks: [
            makeTask(title: "Review chapter 6", dueDate: start.addingTimeInterval(-3600))
        ])
    }

    private static func preparing() -> KueEvent {
        let start = Date.now.addingTimeInterval(2 * 86_400)
        return makeEvent(title: "Preparing Fixture", eventType: .interview, startDate: start, tasks: [
            makeTask(title: "Prepare talking points", dueDate: start.addingTimeInterval(-3600))
        ])
    }

    private static func tomorrow() -> KueEvent {
        makeEvent(title: "Tomorrow Fixture", eventType: .generic, startDate: .now.addingTimeInterval(20 * 3600))
    }

    private static func startingNow() -> KueEvent {
        makeEvent(title: "Starting Now Fixture", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30)
    }

    private static func inProgress() -> KueEvent {
        makeEvent(title: "In Progress Fixture", eventType: .trip, startDate: .now.addingTimeInterval(-1800), estimatedDurationMinutes: 90)
    }

    private static func needsReview() -> KueEvent {
        makeEvent(title: "Needs Review Fixture", eventType: .deadline, startDate: .now.addingTimeInterval(-2 * 3600), estimatedDurationMinutes: 60)
    }

    private static func completedFixture() -> KueEvent {
        makeEvent(title: "Completed Fixture", eventType: .generic, startDate: .now.addingTimeInterval(-86_400), isManuallyCompleted: true, tasks: [
            makeTask(title: "Wrap up notes", dueDate: .now.addingTimeInterval(-90_000), isCompleted: true)
        ])
    }

    private static func cancelledFixture() -> KueEvent {
        makeEvent(title: "Cancelled Fixture", eventType: .exam, startDate: .now.addingTimeInterval(5 * 86_400), isCancelled: true)
    }

    private static func skippedFixture() -> KueEvent {
        makeEvent(title: "Skipped Fixture", eventType: .generic, startDate: .now.addingTimeInterval(2 * 86_400), isSkipped: true)
    }

    private static func archivedFixture() -> KueEvent {
        makeEvent(title: "Archived Fixture", eventType: .generic, startDate: .now.addingTimeInterval(-10 * 86_400), status: .archived)
    }

    private static func longTitleFixture() -> KueEvent {
        makeEvent(
            title: "Second-Round Interview With the Entire Platform Engineering Leadership Team and Extended Panel",
            eventType: .interview,
            startDate: .now.addingTimeInterval(4 * 86_400)
        )
    }

    private static func noTasksFixture() -> KueEvent {
        makeEvent(title: "No Tasks Fixture", eventType: .deadline, startDate: .now.addingTimeInterval(3 * 86_400))
    }

    private static func manyTasksFixture() -> KueEvent {
        let start = Date.now.addingTimeInterval(3 * 86_400)
        let tasks = (0..<6).map { index in
            makeTask(title: "Task \(index + 1)", dueDate: start.addingTimeInterval(TimeInterval(-3600 * (6 - index))), isCompleted: index < 2, sortOrder: index)
        }
        return makeEvent(title: "Many Tasks Fixture", eventType: .exam, startDate: start, tasks: tasks)
    }

    private static func threeDigitCountdownFixture() -> KueEvent {
        makeEvent(title: "Three-Digit Countdown Fixture", eventType: .trip, startDate: .now.addingTimeInterval(128 * 86_400))
    }
}
#endif
