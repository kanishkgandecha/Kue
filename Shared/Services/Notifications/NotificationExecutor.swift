//
//  NotificationExecutor.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Scheduling executor". The one
//  platform boundary that actually talks to the system notification center. Consumes a
//  `NotificationSchedulePlan` — it never re-derives which candidates should exist, only turns
//  "this plan's `scheduledCandidates`" into real requests via diff-based reconciliation
//  against whatever Kue-owned requests are currently pending.
//
//  Deliberately layered on top of the existing `NotificationScheduling` protocol
//  (`NotificationScheduling.swift`) rather than a second `UNUserNotificationCenter` DI seam —
//  `SystemNotificationScheduler`/`FakeNotificationScheduler` already exist, are already used
//  throughout `EventActions`/`WidgetIntentActions`/etc., and this executor's job (add/remove/
//  read-pending/read-authorization) is exactly what that protocol already exposes. No macOS-
//  specific implementation exists because `UNUserNotificationCenter` behaves identically for a
//  local (non-push) notification on macOS — `KueMac` reads through the same
//  `NotificationScheduling`-backed executor; see docs/31 "Mac behavior."
//

import Foundation
import UserNotifications

nonisolated struct NotificationReconciliationResult: Equatable {
    var added: Set<String>
    var removed: Set<String>
    /// docs/31 "Scheduling executor": "Use a ... Failure-injection fake." Identifiers a real
    /// `add()` call failed for — `NotificationScheduling.add` itself swallows its own error
    /// (`try? await center.add(request)`, matching the pre-existing contract), so this stays
    /// empty against the real system scheduler; only `FailingNotificationScheduling` (test-only,
    /// below) actually reports failures here.
    var failedToAdd: Set<String>
}

enum NotificationExecutor {
    /// Every identifier this plan's *desired* schedule should occupy — the diff's "after."
    static func desiredIdentifiers(for plan: NotificationSchedulePlan) -> Set<String> {
        Set(plan.scheduledCandidates.map(\.identifier))
    }

    /// docs/31 "Scheduling executor": "Use a diff-based reconciliation: Desired requests vs.
    /// Pending Kue requests → Add / replace / remove." `knownIdentifiers` is every identifier
    /// this event/task graph could ever occupy (from `NotificationCandidateBuilder
    /// .allIdentifiers` plus every `NotificationRule`'s own `"<event>-rule-<rule>"` form) —
    /// scoping removal to exactly that set is what guarantees this never touches a pending
    /// request belonging to a different Kue identifier namespace or another app entirely
    /// (`UNUserNotificationCenter`'s pending list is already per-app, so "another app" isn't a
    /// real risk here — the real one this scopes against is a stale identifier from a since-
    /// deleted rule/task lingering forever).
    @discardableResult
    static func reconcile(
        plan: NotificationSchedulePlan,
        knownIdentifiers: Set<String>,
        scheduler: NotificationScheduling,
        globalPreferences: NotificationGlobalPreferences
    ) async -> NotificationReconciliationResult {
        let desired = desiredIdentifiers(for: plan)
        let pending = Set(await scheduler.pendingRequestIdentifiers()).intersection(knownIdentifiers)

        let toRemove = pending.subtracting(desired)
        if !toRemove.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: Array(toRemove))
        }

        for candidate in plan.scheduledCandidates {
            let request = makeRequest(for: candidate, globalPreferences: globalPreferences)
            await scheduler.add(request)
        }

        // A real add() failure is swallowed inside `NotificationScheduling.add` itself (matching
        // the pre-existing contract) — the failure-injection fake (KueTests/) instead exposes
        // what it declined to add via its own `pendingRequestIdentifiers()`, so a test compares
        // `desired` against what the fake actually holds afterward rather than reading a
        // `failedToAdd` set this function can't itself observe against a real scheduler.
        return NotificationReconciliationResult(added: desired.subtracting(pending), removed: toRemove, failedToAdd: [])
    }

    /// Builds the actual `UNNotificationRequest` a scheduled candidate becomes — the one place
    /// sound/interruption/grouping/badge preferences turn into real `UNMutableNotificationContent`
    /// fields. Never requests the Critical Alert entitlement/interruption level — docs/31's own
    /// explicit constraint; `NotificationInterruptionPreference` has no `.critical` case at all.
    static func makeRequest(for candidate: NotificationScheduledCandidate, globalPreferences: NotificationGlobalPreferences) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = candidate.sound == .silent ? nil : .default
        if globalPreferences.badgeEnabled { content.badge = 1 }
        // Kue 3.0 Phase 7 — docs/35: a Daily/Weekly Summary candidate has no owning event
        // (`eventID == nil`) — grouped under its own fixed thread instead of being force-
        // unwrapped or silently ungrouped.
        if globalPreferences.groupNotificationsByEvent {
            content.threadIdentifier = candidate.eventID?.uuidString ?? candidate.identifier
        }
        switch candidate.interruptionPreference {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active
        case .timeSensitive:
            content.interruptionLevel = globalPreferences.timeSensitiveEnabled ? .timeSensitive : .active
        }
        // The outcome-follow-up's own actionable category (Mark Completed/Reschedule/Skip/
        // Cancel — docs/25 "K.") — the one existing category this phase reuses verbatim, never
        // a duplicated/second category for the same four actions.
        let isOutcomeFollowUp = candidate.identifier.hasSuffix("-outcome-follow-up") || candidate.explanation == "Outcome follow-up"
        if isOutcomeFollowUp {
            content.categoryIdentifier = NotificationActionIdentifiers.outcomeFollowUpCategory
        } else if let snoozeMinutes = candidate.snoozeMinutes {
            // Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze": every other
            // rule-sourced candidate (default-layer candidates never carry `snoozeMinutes`,
            // per `NotificationScheduledCandidate`'s own header) gets the snooze action.
            content.categoryIdentifier = NotificationActionIdentifiers.ruleSnoozeCategory
            content.userInfo[NotificationActionIdentifiers.snoozeMinutesUserInfoKey] = snoozeMinutes
        }

        let interval = max(candidate.effectiveDeliveryDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: candidate.identifier, content: content, trigger: trigger)
    }
}
