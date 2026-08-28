//
//  EventStatusEngineTests.swift
//  KueTests
//
//  Covers docs/04-event-types.md "Status transition rules" / "Reconciliation" boundaries —
//  see docs/10-testing-strategy.md "Event engine" for the required cases this maps to.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

struct EventStatusEngineTests {

    private func makeEvent(
        eventType: EventType = .interview,
        startDate: Date,
        endDate: Date? = nil,
        estimatedDurationMinutes: Int = 60,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = "UTC",
        isCancelled: Bool = false,
        cancelledAt: Date? = nil,
        isManuallyCompleted: Bool = false,
        manuallyCompletedAt: Date? = nil
    ) -> KueEvent {
        KueEvent(
            title: "Test",
            eventType: eventType,
            startDate: startDate,
            endDate: endDate,
            estimatedDurationMinutes: estimatedDurationMinutes,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            source: .manual,
            isCancelled: isCancelled,
            cancelledAt: cancelledAt,
            isManuallyCompleted: isManuallyCompleted,
            manuallyCompletedAt: manuallyCompletedAt
        )
    }

    // MARK: - Date-driven boundaries

    @Test func moreThanOneDayOutIsUpcoming() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: now.addingTimeInterval(5 * 86_400))
        #expect(EventStatusEngine.derive(for: event, now: now) == .upcoming)
    }

    @Test func exactlyOneCalendarDayOutIsTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9))!
        let event = makeEvent(startDate: start, timeZoneIdentifier: "UTC")
        #expect(EventStatusEngine.derive(for: event, now: now) == .tomorrow)
    }

    @Test func sameCalendarDayBeforeStartTimeIsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let event = makeEvent(startDate: start, timeZoneIdentifier: "UTC")
        #expect(EventStatusEngine.derive(for: event, now: now) == .today)
    }

    @Test func betweenStartAndEffectiveEndIsActive() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60)
        let now = start.addingTimeInterval(30 * 60)
        #expect(EventStatusEngine.derive(for: event, now: now) == .active)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "A./N.1": passing time alone must never mark an event
    // Completed — that was exactly the incident this phase corrects (see docs/25's own
    // header). An event with no explicit `isManuallyCompleted` derives Awaiting Outcome once
    // it's past its effective end, not Completed.
    @Test func afterEffectiveEndIsAwaitingOutcomeNotCompleted() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60)
        let now = start.addingTimeInterval(61 * 60)
        #expect(EventStatusEngine.derive(for: event, now: now) == .awaitingOutcome)
    }

    @Test func zeroDurationEventSkipsActiveIntoAwaitingOutcome() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(eventType: .deadline, startDate: start, estimatedDurationMinutes: 0)
        #expect(EventStatusEngine.derive(for: event, now: start.addingTimeInterval(-1)) == .today)
        #expect(EventStatusEngine.derive(for: event, now: start) == .awaitingOutcome)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "N.2": explicit manual completion still reads as Completed
    // regardless of how much time has passed since — the one path that's allowed to.
    @Test func manuallyCompletedPastEffectiveEndStaysCompleted() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60, isManuallyCompleted: true, manuallyCompletedAt: start.addingTimeInterval(30 * 60))
        #expect(EventStatusEngine.derive(for: event, now: start.addingTimeInterval(61 * 60)) == .completed)
    }

    @Test func allDayEventStaysTodayUntilEndOfDayNotStartInstant() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let event = makeEvent(eventType: .deadline, startDate: midnight, isAllDay: true, timeZoneIdentifier: "UTC")

        // Still "today" moments before midnight starts and moments after it starts —
        // an all-day event never becomes .active and doesn't complete at the opening instant.
        #expect(EventStatusEngine.derive(for: event, now: midnight) == .today)
        #expect(EventStatusEngine.derive(for: event, now: midnight.addingTimeInterval(3600)) == .today)
        #expect(EventStatusEngine.derive(for: event, now: midnight.addingTimeInterval(23 * 3600)) == .today)

        // Kue 2.0 Phase 10.1 — docs/25 "N.3": same "no auto-completion" rule for all-day
        // events once their pinned-timezone day ends.
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        #expect(EventStatusEngine.derive(for: event, now: nextMidnight) == .awaitingOutcome)
    }

    // MARK: - Cancellation / manual completion

    @Test func cancelledOverridesDates() {
        let event = makeEvent(startDate: .distantFuture, isCancelled: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .cancelled)
    }

    @Test func manuallyCompletedOverridesDates() {
        let event = makeEvent(startDate: .distantFuture, isManuallyCompleted: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .completed)
    }

    @Test func cancellationWinsIfBothFlagsSomehowTrue() {
        let event = makeEvent(startDate: .distantFuture, isCancelled: true, isManuallyCompleted: true)
        #expect(EventStatusEngine.derive(for: event, now: .now) == .cancelled)
    }

    // MARK: - Timezone behavior

    @Test func statusUsesStoredTimezoneNotDeviceTimezone() {
        // An event pinned to Tokyo, evaluated at an instant that's "tomorrow" in Tokyo but
        // still "today" in UTC. The stored zone must win.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let startInTokyo = tokyo.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9))!
        // 2026-03-10 20:00 UTC == 2026-03-11 05:00 Tokyo — same Tokyo calendar day as start.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 20))!

        let event = makeEvent(startDate: startInTokyo, timeZoneIdentifier: "Asia/Tokyo")
        #expect(EventStatusEngine.derive(for: event, now: now) == .today)
    }

    // MARK: - Reconciliation / archive

    @Test func reconcilePersistsDerivedStatus() {
        let event = makeEvent(startDate: .distantFuture)
        #expect(event.status == .upcoming) // KueEvent's own init default
        let changed = EventStatusEngine.reconcile(event, now: .now)
        #expect(changed == false) // already .upcoming, nothing to change
    }

    @Test func reconcileNeverRevertsArchive() {
        let event = makeEvent(startDate: .distantFuture)
        event.status = .archived
        let changed = EventStatusEngine.reconcile(event, now: .now)
        #expect(changed == false)
        #expect(event.status == .archived)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "C.": auto-archive only ever fires from an *explicit*
    // terminal state (manually completed here); passing time alone never produces one to
    // archive from in the first place (see the awaiting-outcome test immediately below).
    @Test func reconcileAutoArchivesAfterWindowPastManualCompletion() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 0, isManuallyCompleted: true, manuallyCompletedAt: start)
        EventStatusEngine.reconcile(event, now: start.addingTimeInterval(60))
        #expect(event.status == .completed)

        let wellPastArchiveWindow = start.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        EventStatusEngine.reconcile(event, now: wellPastArchiveWindow)
        #expect(event.status == .archived)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "C./N.8": Awaiting Outcome must never auto-archive merely
    // because time keeps passing — this is the exact regression the old
    // `afterEffectiveEndIsCompleted`-style assumption would have hidden.
    @Test func reconcileNeverAutoArchivesAwaitingOutcome() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        EventStatusEngine.reconcile(event, now: start.addingTimeInterval(60))
        #expect(event.status == .awaitingOutcome)

        let wellPastArchiveWindow = start.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        EventStatusEngine.reconcile(event, now: wellPastArchiveWindow)
        #expect(event.status == .awaitingOutcome)
    }

    // Kue 2.0 Phase 10.1 — docs/25 "B.": a legacy fixture whose persisted `status` is already
    // `.completed` from the old auto-completion policy, but was never manually completed,
    // naturally re-derives to Awaiting Outcome on the next reconciliation — no migration, no
    // bulk rewrite, just `derive(for:)` being asked again.
    @Test func legacyAutoCompletedFixtureBecomesAwaitingOutcomeOnReconcile() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: start, estimatedDurationMinutes: 60) // isManuallyCompleted: false
        event.status = .completed // simulates a pre-Phase-10.1 persisted value
        let changed = EventStatusEngine.reconcile(event, now: start.addingTimeInterval(61 * 60))
        #expect(changed == true)
        #expect(event.status == .awaitingOutcome)
    }

    @Test func reconcileAutoArchivesCancelledEventsFromCancelledAt() {
        let cancelledAt = Date(timeIntervalSince1970: 1_000_000_000)
        let event = makeEvent(startDate: .distantFuture, isCancelled: true, cancelledAt: cancelledAt)
        let wellPast = cancelledAt.addingTimeInterval(Double(EventStatusEngine.autoArchiveDays + 1) * 86_400)
        EventStatusEngine.reconcile(event, now: wellPast)
        #expect(event.status == .archived)
    }

    @Test func sweepUpdatesOnlyNonArchivedEvents() throws {
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let stale = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        stale.status = .upcoming // stale — should be Awaiting Outcome by "now" below
        let archived = makeEvent(startDate: start, estimatedDurationMinutes: 0)
        archived.status = .archived

        context.insert(stale)
        context.insert(archived)
        try context.save()

        let now = start.addingTimeInterval(3600)
        EventStatusEngine.sweep(context: context, now: now)

        // Kue 2.0 Phase 10.1 — docs/25 "F.": no explicit outcome, so Awaiting Outcome, not
        // Completed.
        #expect(stale.status == .awaitingOutcome)
        #expect(archived.status == .archived) // untouched
    }
}
