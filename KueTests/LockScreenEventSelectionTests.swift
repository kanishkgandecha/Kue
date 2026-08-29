//
//  LockScreenEventSelectionTests.swift
//  KueTests
//
//  Post-Phase-12 fix — app-managed Lock Screen widget event selection. Covers the preference
//  (`LockScreenEventSelection`), the eligibility policy
//  (`WidgetContentService.isEligibleForLockScreenSelection`), and the resolution policy
//  (`LockScreenWidgetContentService.resolve`) — three independently-testable pieces, same split
//  `DedicatedCountdownEligibilityTests`/`DedicatedWidgetContentServiceTests` already establish
//  for the sibling Dedicated Countdown feature.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct LockScreenEventSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeEvent(
        title: String = "CAT 2026",
        eventType: EventType = .exam,
        startDate: Date,
        estimatedDurationMinutes: Int = 180,
        isCancelled: Bool = false,
        isSkipped: Bool = false,
        isManuallyCompleted: Bool = false,
        status: EventStatus = .upcoming
    ) -> KueEvent {
        KueEvent(
            title: title, eventType: eventType, startDate: startDate, estimatedDurationMinutes: estimatedDurationMinutes,
            timeZoneIdentifier: "UTC", source: .manual, status: status,
            isCancelled: isCancelled, isManuallyCompleted: isManuallyCompleted, isSkipped: isSkipped
        )
    }

    // MARK: - Preference (requirements 1–4, 13)

    /// `LockScreenEventSelection` is real App Group `UserDefaults` state — cleared before and
    /// after each test in this section so no test can leak its own selection into another
    /// (same rationale `SyncPreferenceTestLock`'s own header documents for a different real
    /// preference; this one has no cross-suite user in this test target, so a plain
    /// clear-before/after is enough without a cross-suite lock).
    private func withCleanSelection(_ body: () throws -> Void) rethrows {
        LockScreenEventSelection.clear(reloader: FakeWidgetReloader())
        defer { LockScreenEventSelection.clear(reloader: FakeWidgetReloader()) }
        try body()
    }

    @Test func noStoredSelectionProducesNil() throws {
        try withCleanSelection {
            #expect(LockScreenEventSelection.current == nil)
        }
    }

    @Test func selectingAnEventPersistsItsUUID() throws {
        try withCleanSelection {
            let id = UUID()
            LockScreenEventSelection.select(id, reloader: FakeWidgetReloader())
            #expect(LockScreenEventSelection.current == id)
        }
    }

    @Test func clearingTheSelectionRemovesIt() throws {
        try withCleanSelection {
            LockScreenEventSelection.select(UUID(), reloader: FakeWidgetReloader())
            LockScreenEventSelection.clear(reloader: FakeWidgetReloader())
            #expect(LockScreenEventSelection.current == nil)
        }
    }

    /// Requirement 3 — "the app and widget read the same App Group preference." Both sides of
    /// this feature only ever go through this one type (never a second reader/writer), so this
    /// proves two independent reads of `current` after one write agree — the same behavioral
    /// guarantee as two different processes reading the same App Group `UserDefaults` suite.
    @Test func appAndWidgetReadTheSameStoredSelection() throws {
        try withCleanSelection {
            let id = UUID()
            LockScreenEventSelection.select(id, reloader: FakeWidgetReloader())
            let readFromAppSide = LockScreenEventSelection.current
            let readFromWidgetSide = LockScreenEventSelection.current
            #expect(readFromAppSide == id)
            #expect(readFromAppSide == readFromWidgetSide)
        }
    }

    // MARK: - Reload triggering (requirement 17)

    @Test func selectingRequestsATimelineReload() throws {
        try withCleanSelection {
            let reloader = FakeWidgetReloader()
            LockScreenEventSelection.select(UUID(), reloader: reloader)
            #expect(reloader.reloadedKinds == [WidgetKind.kue])
        }
    }

    @Test func clearingRequestsATimelineReload() throws {
        try withCleanSelection {
            let reloader = FakeWidgetReloader()
            LockScreenEventSelection.clear(reloader: reloader)
            #expect(reloader.reloadedKinds == [WidgetKind.kue])
        }
    }

    // MARK: - Eligibility for new selection (requirement: eligibility rules)

    @Test func upcomingEventIsEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        #expect(WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    /// Unlike Next Up/Dedicated Countdown, an awaiting-outcome event *is* eligible for a fresh
    /// Lock Screen pick — this feature's own spec explicitly names it eligible, distinct from
    /// the other two policies.
    @Test func awaitingOutcomeEventIsEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        #expect(EventStatusEngine.derive(for: event, now: now) == .awaitingOutcome)
        #expect(WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    @Test func cancelledEventIsNotEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), isCancelled: true)
        #expect(!WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    @Test func skippedEventIsNotEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), isSkipped: true)
        #expect(!WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    @Test func manuallyCompletedEventIsNotEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(-10 * 86_400), isManuallyCompleted: true)
        #expect(!WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    @Test func archivedEventIsNotEligible() {
        let event = makeEvent(startDate: now.addingTimeInterval(-30 * 86_400), status: .archived)
        #expect(!WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }

    /// Requirement 6 — the automatic Next-Up `WidgetConfiguration.isEnabled` flag must never
    /// be consulted here, unlike `isEligibleForAutomaticSelection`.
    @Test func eligibilityIgnoresTheAutomaticWidgetIsEnabledFlag() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown, isEnabled: false)
        #expect(WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
        #expect(!WidgetContentService.isEligibleForAutomaticSelection(event, now: now))
    }

    // MARK: - Resolution: a stored selection always resolves by UUID (requirements 5, 7)

    @Test func validSelectedEventResolvesToTracking() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        guard case .tracking(let content) = resolution else {
            Issue.record("expected .tracking, got \(resolution)")
            return
        }
        #expect(content.eventID == event.id)
    }

    /// Requirement 7 — given a resolved selection, nothing in this policy ever substitutes a
    /// *different* event. The function's own signature (one optional `KueEvent`, never an
    /// events array) is the structural proof: there is no code path here that could even see
    /// another event, mirroring `DedicatedWidgetContentService`'s own documented guarantee.
    @Test func aDifferentEligibleEventIsNeverSubstituted() {
        let selected = makeEvent(title: "Selected Event", startDate: now.addingTimeInterval(20 * 86_400))
        let resolution = LockScreenWidgetContentService.resolve(event: selected, hasStoredSelection: true, now: now)
        guard case .tracking(let content) = resolution else {
            Issue.record("expected .tracking, got \(resolution)")
            return
        }
        #expect(content.eventID == selected.id)
        #expect(content.eventTitle == "Selected Event")
    }

    // MARK: - Terminal/unavailable states (requirements 8–13)

    @Test func completedSelectedEventProducesAnExplicitTrackingCompletedState() {
        let event = makeEvent(startDate: now.addingTimeInterval(-10 * 86_400), isManuallyCompleted: true)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        guard case .tracking(let content) = resolution else {
            Issue.record("expected .tracking(.completed), got \(resolution)")
            return
        }
        #expect(content.phase == .completed)
    }

    @Test func cancelledSelectedEventProducesAnExplicitCancelledState() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), isCancelled: true)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        #expect(resolution == .cancelled(eventID: event.id, eventTitle: event.title))
    }

    @Test func skippedSelectedEventProducesAnExplicitSkippedState() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400), isSkipped: true)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        #expect(resolution == .skipped(eventID: event.id, eventTitle: event.title))
    }

    /// The selected event still exists (only `event.status` changed), so this still resolves
    /// via `.tracking` (`.removed` phase, "Archived" label) and still deep-links to Event
    /// Detail — an archived row is not the same thing as a deleted one. See
    /// `LockScreenWidgetContentService.swift`'s own header for why this mirrors
    /// `DedicatedWidgetContentService`'s identical precedent.
    @Test func archivedSelectedEventStaysAssociatedAsAnExplicitState() {
        let event = makeEvent(startDate: now.addingTimeInterval(-30 * 86_400), status: .archived)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        guard case .tracking(let content) = resolution else {
            Issue.record("expected .tracking(.removed), got \(resolution)")
            return
        }
        #expect(content.phase == .removed)
        #expect(content.eventID == event.id)
    }

    @Test func deletedSelectionProducesSelectionUnavailable() {
        let resolution = LockScreenWidgetContentService.resolve(event: nil, hasStoredSelection: true, now: now)
        #expect(resolution == .selectionUnavailable)
    }

    @Test func neverSelectedProducesNoSelection() {
        let resolution = LockScreenWidgetContentService.resolve(event: nil, hasStoredSelection: false, now: now)
        #expect(resolution == .noSelection)
    }

    /// Requirement 13 — an invalid/corrupted stored value must fail closed to "no selection,"
    /// never crash and never be treated as a selection that happens to resolve to nothing
    /// differently from a genuinely-cleared one.
    @Test func invalidStoredUUIDFailsClosedToNil() throws {
        try withCleanSelection {
            let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
            defaults.set("not-a-uuid", forKey: "lockScreenWidget.selectedEventID")
            defer { defaults.removeObject(forKey: "lockScreenWidget.selectedEventID") }
            #expect(LockScreenEventSelection.current == nil)
        }
    }

    // MARK: - resolveSelectedEvent (SwiftData lookup)

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerFactory.makeInMemory())
    }

    @Test func resolveSelectedEventFindsTheMatchingRow() {
        let context = makeContext()
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        context.insert(event)
        try? context.save()

        let resolved = LockScreenWidgetContentService.resolveSelectedEvent(selectedEventID: event.id, context: context)
        #expect(resolved?.id == event.id)
    }

    @Test func resolveSelectedEventReturnsNilForANeverStoredID() {
        let context = makeContext()
        #expect(LockScreenWidgetContentService.resolveSelectedEvent(selectedEventID: nil, context: context) == nil)
    }

    @Test func resolveSelectedEventReturnsNilForADeletedID() {
        let context = makeContext()
        #expect(LockScreenWidgetContentService.resolveSelectedEvent(selectedEventID: UUID(), context: context) == nil)
    }

    // MARK: - Deep-link destination mapping (requirements 15–16)

    @Test func trackingResolutionDeepLinksToEventDetail() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: now)
        #expect(resolution.deepLinkDestination == .event(event.id))
    }

    @Test func noSelectionDeepLinksToTheSelectionPage() {
        #expect(LockScreenWidgetResolution.noSelection.deepLinkDestination == .lockScreenEventSelection)
    }

    @Test func selectionUnavailableDeepLinksToTheSelectionPage() {
        #expect(LockScreenWidgetResolution.selectionUnavailable.deepLinkDestination == .lockScreenEventSelection)
    }

    @Test func cancelledResolutionStillDeepLinksToEventDetail() {
        let id = UUID()
        let resolution = LockScreenWidgetResolution.cancelled(eventID: id, eventTitle: "Cancelled Event")
        #expect(resolution.deepLinkDestination == .event(id))
    }

    // MARK: - Existing policies unaffected (requirement 18)

    @Test func automaticNextUpEligibilityIsUnaffectedByTheNewEligibilityHelper() {
        let event = makeEvent(startDate: now.addingTimeInterval(10 * 86_400))
        event.widgetConfiguration = WidgetConfiguration(event: event, widgetType: .countdown, isEnabled: false)
        // Automatic selection still correctly excludes an opted-out event — unchanged by this
        // feature, which never touches `isEligibleForAutomaticSelection` itself.
        #expect(!WidgetContentService.isEligibleForAutomaticSelection(event, now: now))
        #expect(WidgetContentService.nextUpEvent(from: [event], now: now) == nil)
    }

    @Test func dedicatedSelectionEligibilityIsUnaffectedByTheNewEligibilityHelper() {
        // Dedicated Countdown's own eligibility deliberately excludes `.awaitingOutcome`,
        // unlike the new Lock Screen policy — proving the two remain genuinely independent.
        let event = makeEvent(startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 30)
        #expect(EventStatusEngine.derive(for: event, now: now) == .awaitingOutcome)
        #expect(!WidgetContentService.isEligibleForDedicatedSelection(event, now: now))
        #expect(WidgetContentService.isEligibleForLockScreenSelection(event, now: now))
    }
}
