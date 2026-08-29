//
//  SystemLiveActivityManager.swift
//  Kue
//
//  The one file in `LiveActivityManaging`'s call graph that talks to real ActivityKit — see
//  docs/23-live-activities-and-focus-mode.md "A./B." `start(for:)` requests a brand-new
//  activity and, per Apple's own ActivityKit contract, must only ever be invoked from the
//  containing app's own process (`LiveActivityFocusCoordinator`, Kue/) — `update`/`end`/
//  `reconcileFocusedActivity` are safe to call from the widget extension process too (e.g.
//  `WidgetIntentActions`, Shared/), which is exactly why this class lives in `Shared/`
//  rather than being app-only.
//

import Foundation
import ActivityKit

nonisolated final class SystemLiveActivityManager: LiveActivityManaging {
    static let shared = SystemLiveActivityManager()
    private init() {}

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func focusedEventID() async -> UUID? {
        Activity<KueLiveActivityAttributes>.activities.first?.attributes.eventID
    }

    /// Only ever call this from the app's own process — see this file's header.
    func start(for event: KueEvent, now: Date) async -> LiveActivityStartResult {
        guard isAvailable else { return .failed(.authorizationDisabled) }
        if let existingID = await focusedEventID() {
            // Idempotent restart of the same event (requirement L.7: "starting the same
            // event twice without duplication") — anything else is a caller-ordering bug the
            // coordinator's own confirmation flow should have prevented; fail honestly rather
            // than silently starting a second activity.
            if existingID == event.id { return .started }
            return .failed(.anotherEventAlreadyFocused(eventID: existingID))
        }
        let attributes = LiveActivityStateBuilder.attributes(for: event)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            _ = try Activity.request(attributes: attributes, content: content)
            return .started
        } catch {
            return .failed(.requestFailed)
        }
    }

    func update(for event: KueEvent, now: Date) async {
        guard let activity = runningActivity(for: event.id) else { return }
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(eventID: UUID, dismissalPolicy: LiveActivityDismissalPolicy) async {
        for activity in Activity<KueLiveActivityAttributes>.activities where activity.attributes.eventID == eventID {
            await activity.end(nil, dismissalPolicy: activityKitPolicy(dismissalPolicy))
        }
    }

    func endAll() async {
        for activity in Activity<KueLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func reconcileFocusedActivity(with event: KueEvent?, now: Date) async {
        guard let activity = Activity<KueLiveActivityAttributes>.activities.first else { return }

        guard let event else {
            // The focused event no longer exists — show a brief unavailable terminal state
            // (built purely from the activity's own immutable `attributes.eventType`, since
            // there's no `KueEvent` left to read), then end after a short grace period.
            // Requirement G: "must not resolve to Next Up."
            let state = LiveActivityStateBuilder.unavailableContentState(eventType: activity.attributes.eventType, now: now)
            await activity.update(ActivityContent(state: state, staleDate: nil))
            await activity.end(nil, dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPolicy.unavailableGracePeriod)))
            return
        }
        guard activity.attributes.eventID == event.id else { return } // never touch another event's activity

        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        let state = LiveActivityStateBuilder.contentState(for: event, now: now)
        await activity.update(ActivityContent(state: state, staleDate: nil))

        switch resolution {
        case .tracking(let content) where content.phase == .completed || content.phase == .removed:
            await activity.end(nil, dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPolicy.completedGracePeriod)))
        // Kue 2.0 Phase 10.1 — docs/25 "G.": never end immediately (the user might confirm an
        // outcome any moment) and never mark the event Completed automatically — the `.update`
        // above already refreshed it to "Needs Review." Only once a genuinely long grace
        // period passes with no explicit outcome does Kue quietly stop the *activity* — the
        // event itself is untouched, still Awaiting Outcome, still visible in Home's Needs
        // Attention section and Event Detail's outcome card.
        case .tracking(let content) where content.phase == .awaitingOutcome:
            if now >= event.effectiveEndDate.addingTimeInterval(LiveActivityPolicy.awaitingOutcomeGracePeriod) {
                await activity.end(nil, dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPolicy.terminalGracePeriod)))
            }
        case .cancelled, .skipped:
            await activity.end(nil, dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPolicy.terminalGracePeriod)))
        default:
            break // still genuinely tracking — nothing to end
        }
    }

    private func runningActivity(for eventID: UUID) -> Activity<KueLiveActivityAttributes>? {
        Activity<KueLiveActivityAttributes>.activities.first { $0.attributes.eventID == eventID }
    }

    private func activityKitPolicy(_ policy: LiveActivityDismissalPolicy) -> ActivityUIDismissalPolicy {
        switch policy {
        case .immediate: return .immediate
        case .after(let date): return .after(date)
        case .systemDefault: return .default
        }
    }
}

/// docs/23 "Terminal-state policy" — how long a finished/terminal Live Activity stays visible
/// before ActivityKit dismisses it. Not user-configurable; explicit constants so the policy
/// is documented in one place rather than scattered magic numbers.
enum LiveActivityPolicy {
    /// `.completed`/`.removed` (archived) — worth a longer glance, matching typical
    /// end-of-task Live Activity UX (deliveries, timers).
    static let completedGracePeriod: TimeInterval = 60 * 60
    /// Cancelled/skipped — a shorter courtesy window, not a celebration.
    static let terminalGracePeriod: TimeInterval = 5 * 60
    /// The focused event was deleted entirely.
    static let unavailableGracePeriod: TimeInterval = 5 * 60
    /// Kue 2.0 Phase 10.1 (docs/25 "G.") — how long a focused Live Activity keeps showing
    /// "Needs Review" past `effectiveEndDate` with no explicit outcome before Kue quietly
    /// stops updating it. Deliberately longer than the other grace periods — this isn't a
    /// terminal state (the user might still act), so it shouldn't disappear quickly the way a
    /// cancelled/skipped one does.
    static let awaitingOutcomeGracePeriod: TimeInterval = 6 * 60 * 60
}
