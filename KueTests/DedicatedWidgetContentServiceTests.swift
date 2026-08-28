//
//  DedicatedWidgetContentServiceTests.swift
//  KueTests
//
//  Covers docs/22-expanded-and-dedicated-widgets.md "C./D." — the strict Dedicated Countdown
//  selection policy. `resolve(event:now:)`'s own signature (one optional `KueEvent`, never an
//  events array) is itself the structural proof requirement 6/7 ("never call the automatic
//  Next Up path," "adding a newer/earlier/more urgent event must not affect it") holds: there
//  is no code path in this file that could even see another event to switch to.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct DedicatedWidgetContentServiceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // fixed, arbitrary reference instant

    private func makeEvent(
        title: String = "CAT 2026",
        eventType: EventType = .exam,
        startDate: Date,
        estimatedDurationMinutes: Int = 180,
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false,
        seriesID: UUID? = nil
    ) -> KueEvent {
        let event = KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: estimatedDurationMinutes,
            timeZoneIdentifier: "UTC", source: .manual,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, seriesID: seriesID, isSkipped: isSkipped
        )
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown)
        return event
    }

    // MARK: - Dedicated selection (requirement L 1–11)

    @Test func remainsSelectedRegardlessOfASoonerEventExisting() {
        // No sooner/more-urgent event is ever passed to `resolve` at all — that's the point.
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        let sooner = makeEvent(title: "Sooner Deadline", eventType: .deadline, startDate: now.addingTimeInterval(2 * 86_400))
        _ = sooner // constructed only to prove it's never consulted — never handed to resolve()

        let resolution = DedicatedWidgetContentService.resolve(event: cat2026, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.eventTitle == "CAT 2026")
    }

    @Test func remainsSelectedWhenANewlyCreatedEventIsMoreUrgent() {
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        // "Newly created" is simulated by constructing it after the fact — still never passed in.
        let newlyCreated = makeEvent(title: "New Urgent Interview", eventType: .interview, startDate: now.addingTimeInterval(3_600))
        _ = newlyCreated

        let resolution = DedicatedWidgetContentService.resolve(event: cat2026, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.eventID == cat2026.id)
    }

    @Test func editingUpdatesDisplayedContentButPreservesIdentity() {
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(93 * 86_400))
        let originalID = cat2026.id
        let before = DedicatedWidgetContentService.resolve(event: cat2026, now: now)

        cat2026.title = "CAT 2026 (Rescheduled)"
        cat2026.startDate = now.addingTimeInterval(100 * 86_400)
        let after = DedicatedWidgetContentService.resolve(event: cat2026, now: now)

        guard case .tracking(let beforeContent) = before, case .tracking(let afterContent) = after else {
            Issue.record("expected .tracking both times"); return
        }
        #expect(beforeContent.eventID == originalID)
        #expect(afterContent.eventID == originalID) // identity preserved
        #expect(afterContent.eventTitle == "CAT 2026 (Rescheduled)") // content updated
        #expect(beforeContent.subline != afterContent.subline) // countdown updated too
    }

    @Test func completingProducesACompletedTerminalState() {
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(-3_600))
        cat2026.isManuallyCompleted = true
        cat2026.manuallyCompletedAt = now

        let resolution = DedicatedWidgetContentService.resolve(event: cat2026, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.phase == .completed)
        #expect(content.subline == "Completed")
    }

    @Test func completedEventDoesNotFallBackToAnotherEvent() {
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(-3_600))
        cat2026.isManuallyCompleted = true
        let other = makeEvent(title: "Something Else", startDate: now.addingTimeInterval(86_400))
        _ = other

        let resolution = DedicatedWidgetContentService.resolve(event: cat2026, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking, not a fallback"); return }
        #expect(content.eventTitle == "CAT 2026")
    }

    @Test func archivedSelectionStaysAssociatedRatherThanFallingBack() {
        let cat2026 = makeEvent(startDate: now.addingTimeInterval(-10 * 86_400))
        cat2026.status = .archived

        let resolution = DedicatedWidgetContentService.resolve(event: cat2026, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.phase == .removed)
        #expect(content.subline == "Archived")
    }

    @Test func cancelledSelectionProducesAnExplicitCancelledStateNotAFallback() {
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400), isCancelled: true)
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .cancelled(let eventID, let title) = resolution else { Issue.record("expected .cancelled"); return }
        #expect(eventID == event.id)
        #expect(title == "CAT 2026")
    }

    @Test func skippedSelectionProducesAnExplicitSkippedStateNotAFallback() {
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400), isSkipped: true)
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .skipped(let eventID, let title) = resolution else { Issue.record("expected .skipped"); return }
        #expect(eventID == event.id)
        #expect(title == "CAT 2026")
    }

    @Test func cancelledTakesPrecedenceOverSkippedMirroringEventStatusEngine() {
        // Mirrors EventStatusEngine.derive's own documented precedence: cancel > skip.
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400), isCancelled: true, isSkipped: true)
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .cancelled = resolution else { Issue.record("expected .cancelled to win over .skipped"); return }
    }

    @Test func deletedOrNeverConfiguredSelectionProducesUnavailable() {
        // The provider hands `nil` here for both "no KueEvent with this id" and "no id was
        // ever configured" — see docs/22 "D." for why those collapse into one case.
        #expect(DedicatedWidgetContentService.resolve(event: nil, now: now) == .unavailable)
    }

    @Test func reconfiguringToAnotherEventResolvesThatNewEvent() {
        let first = makeEvent(title: "First Event", startDate: now.addingTimeInterval(10 * 86_400))
        let second = makeEvent(title: "Second Event", startDate: now.addingTimeInterval(20 * 86_400))

        let firstResolution = DedicatedWidgetContentService.resolve(event: first, now: now)
        let secondResolution = DedicatedWidgetContentService.resolve(event: second, now: now)

        guard case .tracking(let firstContent) = firstResolution, case .tracking(let secondContent) = secondResolution else {
            Issue.record("expected .tracking both times"); return
        }
        #expect(firstContent.eventID != secondContent.eventID)
        #expect(secondContent.eventTitle == "Second Event")
    }

    @Test func twoIndependentInstancesResolveDifferentEventsWithoutInterference() {
        let eventA = makeEvent(title: "Widget A's Event", startDate: now.addingTimeInterval(5 * 86_400))
        let eventB = makeEvent(title: "Widget B's Event", startDate: now.addingTimeInterval(50 * 86_400))

        let resolutionA = DedicatedWidgetContentService.resolve(event: eventA, now: now)
        let resolutionB = DedicatedWidgetContentService.resolve(event: eventB, now: now)

        guard case .tracking(let contentA) = resolutionA, case .tracking(let contentB) = resolutionB else {
            Issue.record("expected .tracking both times"); return
        }
        #expect(contentA.eventTitle == "Widget A's Event")
        #expect(contentB.eventTitle == "Widget B's Event")
    }

    @Test func existingAutomaticNextUpSelectionIsUnaffectedByTheExtractedEligibilityHelper() {
        // The Phase 8 refactor moved "Next Up"'s inline filter into
        // `isEligibleForAutomaticSelection` — confirms `nextUpEvent` still behaves exactly as
        // before (same scenario `WidgetContentServiceTests.nextUpPicksSoonestEligibleEvent`
        // already covers, repeated here to pin the refactor didn't change automatic behavior).
        let soon = makeEvent(title: "Soon", startDate: now.addingTimeInterval(2 * 86_400))
        let later = makeEvent(title: "Later", startDate: now.addingTimeInterval(10 * 86_400))
        #expect(WidgetContentService.nextUpEvent(from: [later, soon], now: now)?.title == "Soon")
    }

    // MARK: - Date and content (requirement L 13–20)

    @Test func timedCountdownFlowsThroughUnchanged() {
        // 20 days out — solidly past the "≈3 days out" preparation threshold, so this stays
        // in `.countdown` phase and its subline is a plain day count (matching the existing
        // `WidgetContentServiceTests.phaseIsCountdownWhenFarOut` fixture distance).
        let event = makeEvent(startDate: now.addingTimeInterval(20 * 86_400))
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.subline == "20 days")
    }

    @Test func allDayEventUsesCalendarDaySemantics() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let event = KueEvent(
            title: "All-Day Trip", eventType: .trip, startDate: calendar.date(byAdding: .day, value: 20, to: today)!,
            estimatedDurationMinutes: 0, isAllDay: true, timeZoneIdentifier: "UTC", source: .manual
        )
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown)
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.subline == "20 days")
    }

    @Test func pinnedTimezoneIsUsedNotTheCurrentDeviceTimezone() {
        // Event pinned to Tokyo; `now` expressed as a fixed absolute instant — the phase must
        // be computed against Tokyo's own calendar day, not whatever `.current` resolves to
        // on the machine running the test (same pattern KueEvent.effectiveEndDate/HomeTimeline
        // Grouping already establish).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let tokyoNow = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!
        let eventStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 18))!
        let event = makeEvent(startDate: eventStart)
        event.timeZoneIdentifier = "Asia/Tokyo"
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: tokyoNow)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.phase == .today)
    }

    @Test func dstBoundaryIsHandledCorrectly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 1 November 2026 — DST ends in New York. An event the following calendar day, viewed
        // the morning of the transition, must still read as "tomorrow," not off-by-one.
        let transitionMorning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        let nextDayEvent = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        let event = makeEvent(startDate: nextDayEvent)
        event.timeZoneIdentifier = "America/New_York"
        let resolution = DedicatedWidgetContentService.resolve(event: event, now: transitionMorning)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.phase == .tomorrow)
    }

    @Test func recurringOccurrenceIdentityIsTheMaterializedRowNotTheSeries() {
        let seriesID = UUID()
        let thisOccurrence = makeEvent(title: "Weekly Standup", startDate: now.addingTimeInterval(2 * 86_400), seriesID: seriesID)
        let siblingOccurrence = makeEvent(title: "Weekly Standup", startDate: now.addingTimeInterval(9 * 86_400), seriesID: seriesID)

        let resolution = DedicatedWidgetContentService.resolve(event: thisOccurrence, now: now)
        guard case .tracking(let content) = resolution else { Issue.record("expected .tracking"); return }
        #expect(content.eventID == thisOccurrence.id)
        #expect(content.eventID != siblingOccurrence.id) // pinned to one occurrence, not the series
    }

    @Test func unknownEventProducesTheSamePlaceholderAsNeverConfigured() {
        #expect(DedicatedWidgetContentService.resolve(event: nil, now: now) == .unavailable)
    }

    @Test func postCompletionResolutionReflectsTheMutationImmediately() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        let beforeCompletion = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let before) = beforeCompletion else { Issue.record("expected .tracking"); return }
        #expect(before.phase == .completed) // already past effectiveEndDate

        event.isManuallyCompleted = true
        event.title = "CAT 2026 — Done"
        let afterCompletion = DedicatedWidgetContentService.resolve(event: event, now: now)
        guard case .tracking(let after) = afterCompletion else { Issue.record("expected .tracking"); return }
        #expect(after.eventTitle == "CAT 2026 — Done")
    }

    // MARK: - resolveConfiguredEvent — the provider's configuration-to-store lookup
    // (regression coverage for "Edit Widget shows CAT 2026, but the placed widget renders
    // .unavailable" — see docs/22-expanded-and-dedicated-widgets.md's own note. This exercises
    // the exact lookup `DedicatedCountdownProvider.resolveConfiguredEvent` (KueWidget/) is now
    // a one-line wrapper around, with a *real* `ModelContext` over a persisted `KueEvent` —
    // as close to "a real configured intent/entity" as `@testable import Kue` can reach, since
    // `KueWidget/`'s own `AppEntity`/`WidgetConfigurationIntent` types don't compile into this
    // module.)

    @Test func resolveConfiguredEventFindsAPersistedEventByItsConfiguredUUID() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let cat2026 = makeEvent(title: "CAT 2026", startDate: now.addingTimeInterval(93 * 86_400))
        context.insert(cat2026)
        try? context.save()

        let resolved = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: cat2026.id, context: context)
        #expect(resolved?.id == cat2026.id)
        #expect(resolved?.title == "CAT 2026")
    }

    @Test func resolveConfiguredEventFindsTheRightEventAmongMultiplePersistedOnes() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let cat2026 = makeEvent(title: "CAT 2026", startDate: now.addingTimeInterval(93 * 86_400))
        let other = makeEvent(title: "Something Else", startDate: now.addingTimeInterval(2 * 86_400))
        context.insert(cat2026)
        context.insert(other)
        try? context.save()

        let resolved = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: cat2026.id, context: context)
        #expect(resolved?.id == cat2026.id)
        #expect(resolved?.title == "CAT 2026")
    }

    @Test func resolveConfiguredEventProducesNilForAGenuinelyMissingUUID() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let cat2026 = makeEvent(title: "CAT 2026", startDate: now.addingTimeInterval(93 * 86_400))
        context.insert(cat2026)
        try? context.save()

        let missingID = UUID() // deliberately not the id of any persisted event
        let resolved = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: missingID, context: context)
        #expect(resolved == nil)
        #expect(DedicatedWidgetContentService.resolve(event: resolved, now: now) == .unavailable)
    }

    @Test func resolveConfiguredEventProducesNilWhenNoIDWasEverConfigured() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let resolved = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: nil, context: context)
        #expect(resolved == nil)
    }
}
