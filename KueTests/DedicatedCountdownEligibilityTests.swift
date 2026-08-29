//
//  DedicatedCountdownEligibilityTests.swift
//  KueTests
//
//  Regression coverage for a real post-implementation defect: the Dedicated Countdown
//  picker's `eligibleForNewSelection()` (the shared `KueEventEntityQuery`)
//  originally filtered through `WidgetContentService.isEligibleForAutomaticSelection`, which
//  requires `WidgetConfiguration.isEnabled == true` — the "opted out of the *automatic*
//  widget" flag, which has no bearing on an explicit, one-time Dedicated Countdown pick. Any
//  event without a `WidgetConfiguration` yet, or with the automatic widget turned off, was
//  silently excluded from the picker's suggestions and search results with no error (a pure
//  filter returning fewer results isn't a failure WidgetKit/AppIntents logs) — a real event
//  like "CAT 2026" could be entirely unselectable. See docs/22-expanded-and-dedicated-
//  widgets.md "C." for the full correction.
//
//  Fix: `WidgetContentService.isEligibleForDedicatedSelection(_:now:)` — same date/status-live
//  check `isEligibleForAutomaticSelection` uses, but never reads `isEnabled`.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct DedicatedCountdownEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeEvent(
        title: String = "CAT 2026",
        eventType: EventType = .exam,
        startDate: Date,
        estimatedDurationMinutes: Int = 180,
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: estimatedDurationMinutes,
            timeZoneIdentifier: "UTC", source: .manual,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, isSkipped: isSkipped
        )
    }

    // MARK: - The fix itself (requirement 7, bullets 1–2)

    @Test func upcomingEventWithNoWidgetConfigurationIsOfferedForDedicatedSelection() {
        let event = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        #expect(event.widgetConfiguration == nil)
        #expect(WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
    }

    @Test func upcomingEventWithAutomaticWidgetDisabledIsStillOfferedForDedicatedSelection() {
        let event = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown, isEnabled: false)
        #expect(WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
    }

    // MARK: - Automatic Next Up stays unchanged (requirement 7, bullet 3)

    @Test func automaticSelectionStillExcludesAnEventWithNoWidgetConfiguration() {
        let event = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        #expect(!WidgetContentService.isEligibleForAutomaticSelection(event, now: now))
    }

    @Test func automaticSelectionStillExcludesAnEventWithTheAutomaticWidgetDisabled() {
        let event = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown, isEnabled: false)
        #expect(!WidgetContentService.isEligibleForAutomaticSelection(event, now: now))
    }

    @Test func nextUpNeverPicksAnEventWithNoWidgetConfigurationOrWithTheAutomaticWidgetDisabled() {
        let noConfig = makeEvent(title: "No Config", startDate: now.addingTimeInterval(86_400))
        let disabled = makeEvent(title: "Disabled", startDate: now.addingTimeInterval(2 * 86_400))
        disabled.widgetConfiguration = WidgetConfiguration(event: disabled, widgetType: .countdown, isEnabled: false)
        let eligible = makeEvent(title: "Eligible", startDate: now.addingTimeInterval(10 * 86_400))
        eligible.widgetConfiguration = WidgetConfiguration(event: eligible, widgetType: .countdown)

        #expect(WidgetContentService.nextUpEvent(from: [noConfig, disabled, eligible], now: now)?.title == "Eligible")
    }

    // MARK: - Still excluded from new suggestions (requirement 7, bullet 4)

    @Test func completedArchivedCancelledAndSkippedEventsAreExcludedFromDedicatedSuggestions() {
        let completed = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        let archived: KueEvent = {
            let event = makeEvent(startDate: now.addingTimeInterval(86_400))
            event.status = .archived
            return event
        }()
        let cancelled = makeEvent(startDate: now.addingTimeInterval(86_400), isCancelled: true)
        let skipped = makeEvent(startDate: now.addingTimeInterval(86_400), isSkipped: true)

        #expect(!WidgetContentService.isEligibleForDedicatedSelection(completed, now: now))
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(archived, now: now))
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(cancelled, now: now))
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(skipped, now: now))
    }

    @Test func deletedEventsAreExcludedByConstructionSinceTheyAreNeverFetched() {
        // Nothing to assert on `isEligibleForDedicatedSelection` here — a deleted event simply
        // never appears in the fetched `[KueEvent]` the picker filters, same as
        // `KueEventEntityQuery.allEntities()`'s own doc comment states. This test
        // documents the reasoning rather than exercising a SwiftData delete directly (that's
        // covered at the model layer by EventCRUDTests).
        #expect(Bool(true))
    }

    // MARK: - A previously configured terminal event still resolves by identifier (requirement 7, bullet 5)

    @Test func aPreviouslyConfiguredCompletedEventStillResolvesAndRendersItsTerminalState() {
        // Kue 2.0 Phase 10.1 — docs/25 "F.": explicitly (manually) completed, not just
        // time-passed — the one path allowed to actually resolve to `.completed` here.
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30, isManuallyCompleted: true)
        // Even though it's no longer offered for a *new* selection...
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
        // ...resolving an *already*-configured id must still succeed, so the widget can show
        // "Completed" rather than falling back to anything else.
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking(.completed)"); return }
        #expect(content.phase == .completed)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "F.": the far more common case — time passed with no
    // explicit outcome yet — must resolve to Awaiting Outcome, not silently to Completed.
    @Test func aPreviouslyConfiguredEventPastEndWithNoOutcomeResolvesAsAwaitingOutcome() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking(.awaitingOutcome)"); return }
        #expect(content.phase == .awaitingOutcome)
    }

    @Test func aPreviouslyConfiguredCancelledEventStillResolvesAndRendersItsTerminalState() {
        let event = makeEvent(startDate: now.addingTimeInterval(86_400), isCancelled: true)
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .cancelled(let eventID, _) = resolution else { Issue.record("expected .cancelled"); return }
        #expect(eventID == event.id)
    }
}
