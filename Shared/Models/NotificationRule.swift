//
//  NotificationRule.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md. A persisted `NotificationRule` row
//  exists **only** for an explicit event- or task-level customization (an override, an
//  addition, or an explicit disable) — the absence of a row for a given anchor means "inherit
//  the global default," not "no reminder." This is the smallest valid model for that:
//  `NotificationPlanner` (Shared/Services/Notifications/) is what actually merges these rows
//  with `NotificationGlobalPreferences` into the full four-level hierarchy (Global Default →
//  Template → Event → Task) — a rule's `inheritanceSource` is therefore a *computed* concept
//  the planner/UI derive, never a stored column: any row that exists here is by definition an
//  Event- or Task-sourced rule (Global Default/Template rules are synthesized, never rows).
//
//  Never stores a `UNNotificationRequest`/any ActivityKit/UserNotifications framework object —
//  every field is a plain value type, safe to back up/restore/sync later exactly like every
//  other Kue model.
//

import Foundation
import SwiftData

/// What a rule is anchored to. `.outcomeFollowUp` is its own case (not `.eventEnd` with a
/// flag) because it carries distinct default copy ("How did it go?") and distinct action
/// behavior (Confirm Outcome, never a one-tap complete — docs/25 "G.", unchanged by this phase).
enum NotificationRuleAnchor: String, Codable, CaseIterable {
    case eventStart
    case eventEnd
    case outcomeFollowUp
    case taskDue
    case absolute
}

enum NotificationOffsetDirection: String, Codable, CaseIterable {
    case before, at, after
}

enum NotificationOffsetUnit: String, Codable, CaseIterable {
    case minutes, hours, days, weeks

    var secondsPerUnit: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 3_600
        case .days: return 86_400
        case .weeks: return 604_800
        }
    }
}

/// No `.none`/custom-file case — this phase reuses the system default alert sound only
/// (docs/31 "Global settings": a sound *preference*, not a sound-file picker/importer).
enum NotificationSoundOption: String, Codable, CaseIterable {
    case defaultSound
    case silent
}

/// Deliberately has no `.critical` case — docs/31's own explicit constraint: never request the
/// Critical Alert entitlement, never present Critical Alerts as available.
enum NotificationInterruptionPreference: String, Codable, CaseIterable {
    case passive
    case active
    case timeSensitive
}

@Model
final class NotificationRule {
    var id: UUID
    /// Exactly one of `event`/`task` is expected to be set — `NotificationRuleValidator`
    /// enforces this at the app-service layer (SwiftData relationships can't express a sum
    /// type). A future template-level rule is a real, disclosed non-goal of this phase — see
    /// docs/31 "Templates."
    var event: KueEvent?
    var task: KueTask?
    var anchor: NotificationRuleAnchor
    var offsetDirection: NotificationOffsetDirection
    var offsetQuantity: Int
    var offsetUnit: NotificationOffsetUnit
    /// Only meaningful for `.absolute` — a one-time custom date/time independent of any offset.
    var absoluteDate: Date?
    var isEnabled: Bool
    var customTitle: String?
    var customBody: String?
    var sound: NotificationSoundOption
    var interruptionPreference: NotificationInterruptionPreference
    /// The rule-provided default snooze duration (minutes) offered first in the snooze menu —
    /// `nil` means "use the global default options," never a stored `UNNotificationRequest`.
    var snoozeMinutes: Int?
    var createdAt: Date
    var updatedAt: Date
    /// Display order within one owner's rule list — ties broken by `createdAt` when equal.
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        event: KueEvent? = nil,
        task: KueTask? = nil,
        anchor: NotificationRuleAnchor,
        offsetDirection: NotificationOffsetDirection = .before,
        offsetQuantity: Int = 0,
        offsetUnit: NotificationOffsetUnit = .minutes,
        absoluteDate: Date? = nil,
        isEnabled: Bool = true,
        customTitle: String? = nil,
        customBody: String? = nil,
        sound: NotificationSoundOption = .defaultSound,
        interruptionPreference: NotificationInterruptionPreference = .active,
        snoozeMinutes: Int? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.event = event
        self.task = task
        self.anchor = anchor
        self.offsetDirection = offsetDirection
        self.offsetQuantity = offsetQuantity
        self.offsetUnit = offsetUnit
        self.absoluteDate = absoluteDate
        self.isEnabled = isEnabled
        self.customTitle = customTitle
        self.customBody = customBody
        self.sound = sound
        self.interruptionPreference = interruptionPreference
        self.snoozeMinutes = snoozeMinutes
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Signed offset from the anchor point — negative is "before," positive is "after," zero
    /// for "at" regardless of quantity (an "at" rule's quantity is always normalized to 0 by
    /// `NotificationRuleValidator` before save, but this reads correctly either way).
    var offsetSeconds: TimeInterval {
        guard offsetDirection != .at else { return 0 }
        let magnitude = Double(offsetQuantity) * offsetUnit.secondsPerUnit
        return offsetDirection == .before ? -magnitude : magnitude
    }

    /// The owning event, whether this rule is event-level or (via its task) task-level —
    /// `NotificationPlanner`/identifier construction need "which event does this ultimately
    /// belong to" regardless of which relationship is populated.
    var owningEventID: UUID? {
        event?.id ?? task?.event?.id
    }
}
