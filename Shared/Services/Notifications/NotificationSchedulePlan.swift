//
//  NotificationSchedulePlan.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Scheduling planner". Pure output
//  types only — no `UNUserNotificationCenter`, no SwiftData. `NotificationPlanner` (this
//  folder) is the only thing that constructs a `NotificationSchedulePlan`;
//  `NotificationExecutor` (this folder) is the only thing that consumes one.
//

import Foundation

/// docs/31: "Every exclusion must use a typed reason." One case per reason the spec names
/// explicitly — never a generic "unknown"/"failed" catch-all.
enum NotificationExclusionReason: String, Equatable, Codable {
    case masterDisabled
    case disabledOnThisDevice
    case permissionDenied
    case ruleDisabled
    case invalidRule
    case passed
    case eventTerminal
    case taskCompleted
    case quietHoursSuppressed
    case systemCapacityLimit
    case duplicate
    case missingEvent
    case missingTask
    case unsupportedPlatformBehavior
}

/// docs/31 "Quiet hours": "Each rule needs a deterministic quiet-hours behavior." Carried on a
/// scheduled candidate so the transparency UI can show "Requested … / Scheduled … / Reason:
/// Quiet hours" rather than silently adjusting the time.
nonisolated enum NotificationQuietHoursAdjustment: Equatable {
    case none
    case movedToQuietHoursEnd
}

nonisolated struct NotificationScheduledCandidate: Equatable {
    var identifier: String
    var eventID: UUID
    var taskID: UUID?
    /// `nil` for a default-layer candidate (preparation/tomorrow/today/task-due-default) —
    /// only rule-sourced candidates have a real owning `NotificationRule.id`.
    var sourceRuleID: UUID?
    var title: String
    var body: String
    var requestedDeliveryDate: Date
    var effectiveDeliveryDate: Date
    var quietHoursAdjustment: NotificationQuietHoursAdjustment
    var priority: Int
    var sound: NotificationSoundOption
    var interruptionPreference: NotificationInterruptionPreference
    /// The one human-readable "why" the transparency UI shows verbatim — docs/31: "Every
    /// scheduled notification must be explainable."
    var explanation: String
    /// Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze" (section O: "no new
    /// UI-reachable trigger yet"), now completed. `nil` for every default-layer candidate (no
    /// owning rule to carry a snooze preference); for a rule-sourced candidate this is always a
    /// concrete minute count — `NotificationRule.snoozeMinutes` when set, else
    /// `NotificationGlobalPreferences.defaultSnoozeMinutes` (itself falling back to a fixed 10
    /// minutes) — "use the global default" in the rule editor's own picker was never "no
    /// snooze," so every enabled rule-sourced candidate always has *some* applicable duration.
    var snoozeMinutes: Int?

    init(
        identifier: String, eventID: UUID, taskID: UUID? = nil, sourceRuleID: UUID? = nil,
        title: String, body: String, requestedDeliveryDate: Date, effectiveDeliveryDate: Date,
        quietHoursAdjustment: NotificationQuietHoursAdjustment, priority: Int,
        sound: NotificationSoundOption, interruptionPreference: NotificationInterruptionPreference,
        explanation: String, snoozeMinutes: Int? = nil
    ) {
        self.identifier = identifier
        self.eventID = eventID
        self.taskID = taskID
        self.sourceRuleID = sourceRuleID
        self.title = title
        self.body = body
        self.requestedDeliveryDate = requestedDeliveryDate
        self.effectiveDeliveryDate = effectiveDeliveryDate
        self.quietHoursAdjustment = quietHoursAdjustment
        self.priority = priority
        self.sound = sound
        self.interruptionPreference = interruptionPreference
        self.explanation = explanation
        self.snoozeMinutes = snoozeMinutes
    }
}

nonisolated struct NotificationExcludedCandidate: Equatable {
    var identifier: String
    var eventID: UUID?
    var taskID: UUID?
    var sourceRuleID: UUID?
    var reason: NotificationExclusionReason
    var requestedDeliveryDate: Date?
    var explanation: String
}

nonisolated struct NotificationSchedulePlan: Equatable {
    var scheduledCandidates: [NotificationScheduledCandidate]
    var excludedCandidates: [NotificationExcludedCandidate]

    static let empty = NotificationSchedulePlan(scheduledCandidates: [], excludedCandidates: [])
}
