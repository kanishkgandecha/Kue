//
//  LiveActivityActionSet.swift
//  Kue
//
//  Kue 3.0 Phase 2 (docs/30) rebuild — the one pure decision layer both the Lock Screen and
//  every Dynamic Island region read to pick which action(s) apply. Post-Phase-12's own version
//  of this file (`LiveActivityActionSet`/`actionSet(for:)`) let a genuinely-tracking state with
//  a next task offer *three* buttons (Complete Task, Snooze, Mark Complete) — exactly the "no
//  row of three full-width buttons" defect this phase's spec calls out. Replaced with
//  `LiveActivityActionPlan`: at most one primary and one secondary action, always. The
//  secondary is never a second full mutation surface — it's either one clearly-valid quick
//  action (Snooze) or plain navigation to Event Detail, where every other valid action already
//  exists (docs/30 "Action policy": "do not attempt to put the complete Event Detail action set
//  inside the Live Activity"). Lives in `Shared/`, not `KueWidget/`, so `KueTests` can reach it
//  via `@testable import Kue` — same reasoning `EventTypeAccent.swift`'s header documents.
//  Never re-derives lifecycle: it only reads the already-computed `ContentState`.
//
//  Kue 3.0 Phase 1 (macOS Foundation) — `KueLiveActivityAttributes` itself only exists on
//  iOS (see that file's own header); guarded here for the same reason.
//

#if os(iOS)
import Foundation

/// Every action a Live Activity/Dynamic Island control can trigger — each case wraps exactly
/// the identifier the existing App Intent needs (`CompleteTaskIntent`/`SnoozeTaskIntent`/
/// `CompleteEventIntent`) or the existing `KueDeepLink` event route. No mutation logic lives
/// here — this is a menu of which *already-existing* action applies, never a new one.
enum LiveActivityAction: Equatable {
    case completeTask(taskID: UUID)
    case snoozeTask(taskID: UUID)
    case markComplete(eventID: UUID)
    case confirmOutcome(eventID: UUID)
    case openEvent(eventID: UUID)
}

/// At most one of each — the hard ceiling docs/30 "Action policy" sets ("Maximum two visible
/// action controls. One primary action. One compact secondary/overflow action."). Both `nil`
/// means "show no action row at all," not "show an empty one" (terminal/completed/removed).
struct LiveActivityActionPlan: Equatable {
    var primary: LiveActivityAction?
    var secondary: LiveActivityAction?

    static let none = LiveActivityActionPlan(primary: nil, secondary: nil)
}

enum LiveActivityActionPolicy {
    /// The one place every non-mutation-vs-mutation, primary-vs-secondary decision is made.
    /// `eventID` is `attributes.eventID` — the caller already has it; this function stays a
    /// plain `ContentState` → plan mapping so it's trivially unit-testable without needing a
    /// full `KueLiveActivityAttributes` value.
    static func plan(for state: KueLiveActivityAttributes.ContentState, eventID: UUID) -> LiveActivityActionPlan {
        if state.terminal != nil {
            // Terminal/unavailable — docs/30: "No mutation actions. Optional Open Kue/Open
            // Event navigation." A deleted event's `openEvent` link still resolves honestly to
            // `EventUnavailableView` (docs/23 "H."), never a crash — safe to offer unconditionally.
            return LiveActivityActionPlan(primary: nil, secondary: .openEvent(eventID: eventID))
        }
        switch state.phase {
        case .completed, .removed:
            // Same "no mutation, optional navigation" rule — these are the natural terminus of
            // a *phase*, not `terminal`, but the action policy is identical either way.
            return LiveActivityActionPlan(primary: nil, secondary: .openEvent(eventID: eventID))
        case .awaitingOutcome:
            // Kue 2.0 Phase 10.1 (docs/25 "G."): never a one-tap complete here. The primary
            // action already deep-links to Event Detail's outcome flow (see the views), so a
            // second "Open Event" secondary would target the identical destination — dropped
            // entirely rather than shown as a pointless duplicate control.
            return LiveActivityActionPlan(primary: .confirmOutcome(eventID: eventID), secondary: nil)
        case .countdown, .preparation, .tomorrow, .today:
            if let nextTaskID = state.nextTaskID {
                let secondary: LiveActivityAction = state.canSnoozeNextTask
                    ? .snoozeTask(taskID: nextTaskID)
                    : .openEvent(eventID: eventID)
                return LiveActivityActionPlan(primary: .completeTask(taskID: nextTaskID), secondary: secondary)
            }
            return LiveActivityActionPlan(primary: .markComplete(eventID: eventID), secondary: .openEvent(eventID: eventID))
        }
    }
}
#endif
