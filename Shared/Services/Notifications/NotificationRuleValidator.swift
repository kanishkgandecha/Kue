//
//  NotificationRuleValidator.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Rule editor" bounds. Pure — no
//  SwiftData, no dates compared against a live `Date()` unless explicitly passed `now`, so
//  every branch is deterministically testable. Used by the rule editor (reject before save),
//  `BackupRestoreService` (reject a corrupted/foreign rule without touching existing data), and
//  `NotificationPlanner` (an already-invalid stored rule is excluded with `.invalidRule` rather
//  than crashing or silently misfiring).
//

import Foundation

enum NotificationRuleValidationError: Error, Equatable {
    /// `.at` must carry a zero offset — a nonzero quantity paired with "at" has no defined
    /// meaning (docs/31: "reject zero/negative combinations that have no defined meaning").
    case atDirectionMustHaveZeroOffset
    /// `.before`/`.after` must carry a strictly positive quantity — zero would be
    /// indistinguishable from "at," and negative has no meaning for a quantity.
    case beforeOrAfterRequiresPositiveOffset
    /// docs/31: "bound extreme offsets... prevent integer overflow."
    case offsetExceedsMaximum(unit: NotificationOffsetUnit, maximum: Int)
    case ownerMustBeExactlyOneOfEventOrTask
    case absoluteAnchorRequiresAbsoluteDate
    case nonAbsoluteAnchorMustNotCarryAbsoluteDate
    case taskDueAnchorRequiresATask
    /// `.eventStart`/`.eventEnd`/`.outcomeFollowUp` all describe an *event*-relative rule —
    /// attaching one to a task-owned row is a foreign/corrupted combination, not a real state
    /// the rule editor can ever produce.
    case eventRelativeAnchorRequiresAnEvent
}

enum NotificationRuleValidator {
    /// docs/31: "bound extreme offsets" — chosen so every unit still comfortably covers any
    /// realistic reminder while keeping the stored `Int` far from any overflow concern.
    /// Minutes: ~2.5 days (near-term precision only — longer gaps read far more naturally in
    /// hours/days/weeks). Hours: ~1 year. Days: ~10 years. Weeks: ~10 years.
    static func maximumOffsetQuantity(for unit: NotificationOffsetUnit) -> Int {
        switch unit {
        case .minutes: return 3_650
        case .hours: return 8_760
        case .days: return 3_650
        case .weeks: return 520
        }
    }

    /// Validates the semantic combination a `NotificationRule` (or its editor draft) carries.
    /// Never mutates — the caller decides what to do with the first error found.
    static func validate(
        anchor: NotificationRuleAnchor,
        offsetDirection: NotificationOffsetDirection,
        offsetQuantity: Int,
        offsetUnit: NotificationOffsetUnit,
        absoluteDate: Date?,
        hasEventOwner: Bool,
        hasTaskOwner: Bool
    ) throws {
        guard hasEventOwner != hasTaskOwner else {
            throw NotificationRuleValidationError.ownerMustBeExactlyOneOfEventOrTask
        }

        switch anchor {
        case .absolute:
            guard absoluteDate != nil else { throw NotificationRuleValidationError.absoluteAnchorRequiresAbsoluteDate }
        default:
            guard absoluteDate == nil else { throw NotificationRuleValidationError.nonAbsoluteAnchorMustNotCarryAbsoluteDate }
        }

        switch anchor {
        case .eventStart, .eventEnd, .outcomeFollowUp:
            guard hasEventOwner else { throw NotificationRuleValidationError.eventRelativeAnchorRequiresAnEvent }
        case .taskDue:
            guard hasTaskOwner else { throw NotificationRuleValidationError.taskDueAnchorRequiresATask }
        case .absolute:
            break // valid on either an event or a task owner
        }

        // `.absolute` rules carry no offset at all — direction/quantity/unit are unused,
        // ignored rather than validated (the editor keeps them at their harmless defaults).
        guard anchor != .absolute else { return }

        switch offsetDirection {
        case .at:
            guard offsetQuantity == 0 else { throw NotificationRuleValidationError.atDirectionMustHaveZeroOffset }
        case .before, .after:
            guard offsetQuantity > 0 else { throw NotificationRuleValidationError.beforeOrAfterRequiresPositiveOffset }
            let maximum = maximumOffsetQuantity(for: offsetUnit)
            guard offsetQuantity <= maximum else {
                throw NotificationRuleValidationError.offsetExceedsMaximum(unit: offsetUnit, maximum: maximum)
            }
        }
    }

    static func validate(_ rule: NotificationRule) throws {
        try validate(
            anchor: rule.anchor,
            offsetDirection: rule.offsetDirection,
            offsetQuantity: rule.offsetQuantity,
            offsetUnit: rule.offsetUnit,
            absoluteDate: rule.absoluteDate,
            hasEventOwner: rule.event != nil,
            hasTaskOwner: rule.task != nil
        )
    }

    /// docs/31 "Absolute": "Prevent meaningless past scheduling. Show it as Passed or Invalid
    /// rather than pretending it is pending." A pure read, never a validation failure — a
    /// passed absolute date is a valid rule in an already-elapsed state, not a corrupted one.
    static func isAbsoluteDatePassed(_ date: Date, now: Date) -> Bool {
        date <= now
    }
}
