//
//  NotificationRuleValidatorTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Rule validation": every anchor,
//  before/after/at directions, absolute dates, bounds, invalid combinations.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct NotificationRuleValidatorTests {
    @Test func atDirectionWithNonzeroOffsetIsRejected() {
        #expect(throws: NotificationRuleValidationError.atDirectionMustHaveZeroOffset) {
            try NotificationRuleValidator.validate(
                anchor: .eventStart, offsetDirection: .at, offsetQuantity: 5, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test func atDirectionWithZeroOffsetIsValid() throws {
        try NotificationRuleValidator.validate(
            anchor: .eventStart, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
            absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
        )
    }

    @Test(arguments: [-5, 0])
    func beforeOrAfterRequiresAPositiveOffset(quantity: Int) {
        #expect(throws: NotificationRuleValidationError.beforeOrAfterRequiresPositiveOffset) {
            try NotificationRuleValidator.validate(
                anchor: .eventStart, offsetDirection: .before, offsetQuantity: quantity, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test func offsetBeyondTheUnitsMaximumIsRejected() {
        let maximum = NotificationRuleValidator.maximumOffsetQuantity(for: .days)
        #expect(throws: NotificationRuleValidationError.offsetExceedsMaximum(unit: .days, maximum: maximum)) {
            try NotificationRuleValidator.validate(
                anchor: .eventStart, offsetDirection: .before, offsetQuantity: maximum + 1, offsetUnit: .days,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test func offsetAtExactlyTheMaximumIsValid() throws {
        let maximum = NotificationRuleValidator.maximumOffsetQuantity(for: .weeks)
        try NotificationRuleValidator.validate(
            anchor: .eventStart, offsetDirection: .before, offsetQuantity: maximum, offsetUnit: .weeks,
            absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
        )
    }

    @Test func ownerMustBeExactlyOneOfEventOrTaskNeitherIsRejected() {
        #expect(throws: NotificationRuleValidationError.ownerMustBeExactlyOneOfEventOrTask) {
            try NotificationRuleValidator.validate(
                anchor: .absolute, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: .now, hasEventOwner: false, hasTaskOwner: false
            )
        }
    }

    @Test func ownerMustBeExactlyOneOfEventOrTaskBothIsRejected() {
        #expect(throws: NotificationRuleValidationError.ownerMustBeExactlyOneOfEventOrTask) {
            try NotificationRuleValidator.validate(
                anchor: .absolute, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: .now, hasEventOwner: true, hasTaskOwner: true
            )
        }
    }

    @Test func absoluteAnchorWithoutADateIsRejected() {
        #expect(throws: NotificationRuleValidationError.absoluteAnchorRequiresAbsoluteDate) {
            try NotificationRuleValidator.validate(
                anchor: .absolute, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test func nonAbsoluteAnchorCarryingAnAbsoluteDateIsRejected() {
        #expect(throws: NotificationRuleValidationError.nonAbsoluteAnchorMustNotCarryAbsoluteDate) {
            try NotificationRuleValidator.validate(
                anchor: .eventStart, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: .now, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test(arguments: [NotificationRuleAnchor.eventStart, .eventEnd, .outcomeFollowUp])
    func eventRelativeAnchorsRequireAnEventOwner(anchor: NotificationRuleAnchor) {
        #expect(throws: NotificationRuleValidationError.eventRelativeAnchorRequiresAnEvent) {
            try NotificationRuleValidator.validate(
                anchor: anchor, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: false, hasTaskOwner: true
            )
        }
    }

    @Test func taskDueAnchorRequiresATaskOwner() {
        #expect(throws: NotificationRuleValidationError.taskDueAnchorRequiresATask) {
            try NotificationRuleValidator.validate(
                anchor: .taskDue, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
                absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
            )
        }
    }

    @Test func absoluteAnchorIsValidOnEitherOwnerKind() throws {
        try NotificationRuleValidator.validate(
            anchor: .absolute, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
            absoluteDate: .now, hasEventOwner: true, hasTaskOwner: false
        )
        try NotificationRuleValidator.validate(
            anchor: .absolute, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes,
            absoluteDate: .now, hasEventOwner: false, hasTaskOwner: true
        )
    }

    @Test func everyUnitAndDirectionCombinationValidatesConsistently() throws {
        for unit in NotificationOffsetUnit.allCases {
            for direction: NotificationOffsetDirection in [.before, .after] {
                try NotificationRuleValidator.validate(
                    anchor: .eventStart, offsetDirection: direction, offsetQuantity: 1, offsetUnit: unit,
                    absoluteDate: nil, hasEventOwner: true, hasTaskOwner: false
                )
            }
        }
    }

    // MARK: - Absolute-date passed/pending

    @Test func absoluteDateInThePastIsPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(NotificationRuleValidator.isAbsoluteDatePassed(now.addingTimeInterval(-1), now: now))
    }

    @Test func absoluteDateInTheFutureIsNotPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!NotificationRuleValidator.isAbsoluteDatePassed(now.addingTimeInterval(1), now: now))
    }
}
