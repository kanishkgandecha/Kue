//
//  KueLiveActivityAttributes.swift
//  Kue
//
//  See docs/23-live-activities-and-focus-mode.md "B. ActivityKit attributes/state contract."
//  Everything here is Codable/Hashable value data only — no SwiftData model objects, no
//  ModelContext, no large task arrays. `ContentState` carries just enough to render the Lock
//  Screen/Dynamic Island without a second fetch; `LiveActivityStateBuilder` is what actually
//  computes one from a real `KueEvent`, reusing `DedicatedWidgetContentService`/
//  `WidgetContentService` rather than re-deriving lifecycle rules here.
//
//  Kue 3.0 Phase 1 (macOS Foundation) — ActivityKit doesn't exist on macOS at all (no Lock
//  Screen/Dynamic Island there), so this whole declaration is guarded with
//  `#if os(iOS)`. `SystemLiveActivityManager.swift`'s own `#else` branch is the
//  only other file that needs to know this type doesn't exist on that platform — see its
//  header for how `EventActions`/`EventReconciliation`/etc.'s `LiveActivityManaging`-typed
//  default parameters still compile everywhere without ever referencing this struct directly.
//

#if os(iOS)
import Foundation
import ActivityKit

/// `nonisolated` — this module defaults new types to `@MainActor`
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`, see AGENTS.md's concurrency note), but
/// `SystemLiveActivityManager.reconcileFocusedActivity`/`end`/etc. construct and compare
/// `KueLiveActivityAttributes` values from `nonisolated` ActivityKit callback contexts.
nonisolated struct KueLiveActivityAttributes: ActivityAttributes {
    /// Everything that changes over the activity's lifetime. `Codable & Hashable` per
    /// `ActivityAttributes.ContentState`'s own requirement — every field is a plain value
    /// type, safe to serialize into the system's own Live Activity storage.
    nonisolated struct ContentState: Codable, Hashable {
        /// Already privacy-resolved by `LiveActivityStateBuilder` — either the real event
        /// title or a generic event-type label (docs/23 "Privacy matrix"). Never re-derive
        /// privacy here; by the time this reaches a view, the decision is already made.
        var displayTitle: String
        var eventTypeDisplayName: String
        /// Reused verbatim from `Shared/Models/WidgetState.swift` — the same six-phase
        /// lifecycle every other Kue widget already renders from.
        var phase: WidgetLifecyclePhase
        var isUrgent: Bool
        var effectiveStartDate: Date
        var effectiveEndDate: Date
        /// The exact, deterministic countdown string `WidgetContentService` already computes
        /// (e.g. "3 days," "Today") — reused, never recomputed, so the Live Activity can never
        /// disagree with what the widgets show for the same event at the same instant.
        var countdownSubline: String?
        var tasksCompleted: Int
        var tasksTotal: Int
        /// Present whenever a next incomplete task exists, regardless of the privacy
        /// preference — needed so the "Complete Task" interactive action (section H, reusing
        /// `CompleteTaskIntent`) still works even when the task's own *title* is hidden. An
        /// id is not itself sensitive content the way a title is.
        var nextTaskID: UUID?
        /// Only populated when both a next incomplete task exists *and* the privacy
        /// preference allows showing it (docs/23 "Privacy matrix").
        var nextTaskSummary: String?
        var remainingTaskCount: Int
        /// Mirrors `WidgetDisplayContent.canSnooze` (`TaskSnoozeCalculator.isSnoozeAvailable`)
        /// — the Live Activity's own Snooze button is hidden, not disabled, once no valid
        /// interval remains, same rule every other Kue widget already follows.
        var canSnoozeNextTask: Bool
        /// `nil` while genuinely tracking the event (including its own `.completed`/`.removed`
        /// phases, which `phase` already expresses); set only for the three states
        /// `WidgetLifecyclePhase` has no case for.
        var terminal: Terminal?
        var lastUpdated: Date

        enum Terminal: String, Codable, Hashable {
            case cancelled, skipped, unavailable
        }
    }

    // MARK: - Immutable attributes (set once, at `Activity.request`)

    /// The materialized occurrence row's own id — never a `seriesID`. A Live Activity is
    /// pinned to one specific occurrence exactly the way the Dedicated Countdown widget is
    /// pinned to one specific `KueEvent.id` (docs/23 "One-event focus invariant").
    var eventID: UUID
    var eventType: EventType
    var isAllDay: Bool
    var timeZoneIdentifier: String
}
#endif
