//
//  NotificationRuleDefault.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults". A plain,
//  non-`@Model` value type a `Template` owns (stored as JSON `Data`, exactly like
//  `Template.scheduleRules`/`KueSchedule.rules` already do — see `ScheduleRule.swift`'s own
//  precedent) rather than a live, relationship-owning `NotificationRule` row. This is
//  deliberate: a template default is a *spec to copy from* at event-creation time, never a
//  live thing with its own identity, cascade-delete, or backup-restore relationship semantics
//  the way an event/task-owned `NotificationRule` is. Choosing this shape over adding a third
//  `NotificationRule.template` relationship avoided a much larger migration (re-nesting the
//  entire `KueEvent`-connected subgraph a second time) for no real benefit — `Template` stays
//  the same kind of untouched-relationship "island" `KueSchemaV2`/`V3`/`V4` already established
//  it as.
//
//  No `.absolute` case, structurally — the exact "do not copy a stale absolute timestamp into
//  newly created events" requirement this phase's own review raised. A template describes a
//  *relative* reminder (before/at/after event start or end, or the outcome follow-up); a
//  one-time custom date has no meaning generalized across every future event created from a
//  type, so the anchor vocabulary here is a strict subset of `NotificationRuleAnchor` that
//  never includes it. No `.taskDue` either — a template has no live `KueTask` to anchor to
//  (tasks are freshly generated per event from `ScheduleRule`, with new ids each time; nothing
//  here could correctly retarget one by identity, same reasoning
//  `OccurrenceReconciliationService.makeOccurrence`'s own header already gives for not copying
//  task-level rules across recurring occurrences).
//

import Foundation

/// Deliberately smaller than `NotificationRuleAnchor` — see this file's own header.
enum TemplateNotificationAnchor: String, Codable, CaseIterable {
    case eventStart, eventEnd, outcomeFollowUp

    var asRuleAnchor: NotificationRuleAnchor {
        switch self {
        case .eventStart: return .eventStart
        case .eventEnd: return .eventEnd
        case .outcomeFollowUp: return .outcomeFollowUp
        }
    }
}

struct NotificationRuleDefault: Codable, Equatable, Identifiable {
    var id: UUID
    var anchor: TemplateNotificationAnchor
    var offsetDirection: NotificationOffsetDirection
    var offsetQuantity: Int
    var offsetUnit: NotificationOffsetUnit
    var isEnabled: Bool
    var customTitle: String?
    var customBody: String?
    var sound: NotificationSoundOption
    var interruptionPreference: NotificationInterruptionPreference
    var snoozeMinutes: Int?

    init(
        id: UUID = UUID(),
        anchor: TemplateNotificationAnchor,
        offsetDirection: NotificationOffsetDirection = .before,
        offsetQuantity: Int = 30,
        offsetUnit: NotificationOffsetUnit = .minutes,
        isEnabled: Bool = true,
        customTitle: String? = nil,
        customBody: String? = nil,
        sound: NotificationSoundOption = .defaultSound,
        interruptionPreference: NotificationInterruptionPreference = .active,
        snoozeMinutes: Int? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.offsetDirection = offsetDirection
        self.offsetQuantity = offsetQuantity
        self.offsetUnit = offsetUnit
        self.isEnabled = isEnabled
        self.customTitle = customTitle
        self.customBody = customBody
        self.sound = sound
        self.interruptionPreference = interruptionPreference
        self.snoozeMinutes = snoozeMinutes
    }

    /// Validates exactly the same way a live `NotificationRule` would for the fields they
    /// share — reuses `NotificationRuleValidator` rather than a second bounds-check.
    func validate() throws {
        try NotificationRuleValidator.validate(
            anchor: anchor.asRuleAnchor, offsetDirection: offsetDirection, offsetQuantity: offsetQuantity,
            offsetUnit: offsetUnit, absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
        )
    }
}
