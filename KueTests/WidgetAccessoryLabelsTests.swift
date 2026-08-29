//
//  WidgetAccessoryLabelsTests.swift
//  KueTests
//
//  Covers docs/22-expanded-and-dedicated-widgets.md "F./G./H." — the accessory-family content
//  policy (requirement L 21–26, 30): short deterministic values, and — critically — never
//  leaking `subline`'s phase-dependent task-title/location content into an accessory family.
//

import Testing
@testable import Kue

struct WidgetAccessoryLabelsTests {
    // MARK: - Compact countdown (requirement 21–26: family content policy)

    @Test func countdownPhaseCompactsANumericSublineToADayCount() {
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .countdown, subline: "93 days") == "93d")
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .countdown, subline: "1 day") == "1d")
    }

    @Test func countdownPhaseFallsBackToAPlaceholderWhenSublineIsNil() {
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .countdown, subline: nil) == "—")
    }

    @Test func countdownPhasePassesThroughANonNumericSublineUnchanged() {
        // Defensive: `.countdown`'s own subline is always numeric in practice, but the
        // function must still degrade safely rather than produce "0d" or crash.
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .countdown, subline: "Soon") == "Soon")
    }

    @Test func completedAndArchivedPhasesAlwaysReadCompletedOrArchived() {
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .completed, subline: "anything") == "Completed")
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .removed, subline: nil) == "Archived")
    }

    // MARK: - Privacy (requirement 30: privacy-sensitive fields never in accessory families)

    @Test func preparationPhaseNeverExposesTheUnderlyingTaskTitle() {
        // `.preparation`'s real `subline` (from WidgetContentService.displayContent) is the
        // next incomplete task's *title* — a genuine "task detail" requirement H forbids in
        // accessory families. The safe status must be the fixed word, never that title.
        let taskTitleAsSubline = "Buy a birthday gift for Mom"
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .preparation, subline: taskTitleAsSubline) == "Preparing")
    }

    @Test func tomorrowPhaseNeverExposesTheUnderlyingTaskTitle() {
        let taskTitleAsSubline = "Confidential prep note"
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .tomorrow, subline: taskTitleAsSubline) == "Tomorrow")
    }

    @Test func todayPhaseNeverExposesTheUnderlyingLocation() {
        // `.today`'s real `subline` (when `showLocation` is on) is the event's location text.
        let locationAsSubline = "123 Private Street, Apt 4B"
        #expect(WidgetAccessoryLabels.accessorySafeStatus(phase: .today, subline: locationAsSubline) == "Today")
    }
}
