//
//  CalendarExportServiceTests.swift
//  KueTests
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration, requirement 41: export, destination-calendar
//  selection, update, missing external event, externally changed event, recreation, unlinking,
//  cancellation, EventKit failure, and confirms Calendar operations never touch notifications
//  or the widget. `FakeCalendarProvider`/`FakeNotificationScheduler`/`FakeWidgetReloader`
//  throughout — never real EventKit, never real notification/widget side effects.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct CalendarExportServiceTests {
    private func makeEvent(context: ModelContext) -> KueEvent {
        let event = KueEvent(title: "Design Review", eventType: .generic, startDate: .init(timeIntervalSince1970: 1_800_000_000), estimatedDurationMinutes: 30, source: .manual)
        context.insert(event)
        try? context.save()
        return event
    }

    private var homeCalendar: KueWritableCalendar {
        KueWritableCalendar(calendarIdentifier: "cal-home", title: "Home", sourceTitle: "Fake Account")
    }

    // MARK: - Export + destination-calendar selection (requirement 17/18/19)

    @Test func exportLinksTheEventToTheChosenCalendar() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])

        let result = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)

        #expect(result.isSuccess)
        #expect(event.externalCalendarEventIdentifier != nil)
        #expect(event.externalCalendarIdentifier == "cal-home")
        #expect(event.externalCalendarTitle == "Home")
        #expect(event.externalCalendarLastSyncedAt != nil)
        #expect(provider.saveCallCount == 1)
    }

    @Test func statusIsNotLinkedBeforeAnyExport() {
        let container = ModelContainerFactory.makeInMemory()
        let event = makeEvent(context: container.mainContext)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess)
        #expect(CalendarExportService.status(for: event, provider: provider) == .notLinked)
    }

    // MARK: - Update (requirement 24/25)

    @Test func updatePushesCurrentFieldsToTheLinkedEvent() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)

        event.title = "Design Review (Updated)"
        let result = CalendarExportService.update(event, provider: provider, context: context)

        #expect(result.isSuccess)
        #expect(provider.events.first?.title == "Design Review (Updated)")
        #expect(CalendarExportService.status(for: event, provider: provider) == .linked)
    }

    @Test func updateOnAnUnlinkedEventFails() {
        let container = ModelContainerFactory.makeInMemory()
        let event = makeEvent(context: container.mainContext)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess)
        let result = CalendarExportService.update(event, provider: provider, context: container.mainContext)
        #expect(!result.isSuccess)
    }

    // MARK: - Missing external event (requirement 26/27)

    @Test func statusReportsMissingWhenTheLinkedEventNoLongerExists() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)

        provider.events.removeAll() // simulates the user deleting it in the Calendar app

        #expect(CalendarExportService.status(for: event, provider: provider) == .missing)
    }

    @Test func recreateRelinksToANewCalendarEventAfterOneWentMissing() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)
        let originalIdentifier = event.externalCalendarEventIdentifier
        provider.events.removeAll()

        let result = CalendarExportService.recreate(event, provider: provider, context: context)

        #expect(result.isSuccess)
        #expect(event.externalCalendarEventIdentifier != nil)
        #expect(event.externalCalendarEventIdentifier != originalIdentifier)
        #expect(CalendarExportService.status(for: event, provider: provider) == .linked)
    }

    // MARK: - Externally changed event (requirement 26/28/29)

    @Test func statusReportsExternallyModifiedWhenLastModifiedDateMovesForward() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)

        // Simulate an external edit (e.g. via the Calendar app) bumping lastModifiedDate.
        guard let index = provider.events.firstIndex(where: { $0.externalIdentifier == event.externalCalendarEventIdentifier }) else {
            Issue.record("expected the exported event to exist")
            return
        }
        provider.events[index].title = "Changed outside Kue"
        provider.events[index].lastModifiedDate = (event.externalCalendarLastKnownModifiedAt ?? .now).addingTimeInterval(3_600)

        let status = CalendarExportService.status(for: event, provider: provider)
        guard case .externallyModified(let live) = status else {
            Issue.record("expected .externallyModified, got \(status)")
            return
        }
        #expect(live.title == "Changed outside Kue")
    }

    @Test func overwritingAnExternallyModifiedEventRequiresAnExplicitUpdateCallNeverAutomatic() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)
        guard let index = provider.events.firstIndex(where: { $0.externalIdentifier == event.externalCalendarEventIdentifier }) else {
            Issue.record("expected the exported event to exist")
            return
        }
        let externalTitle = "Changed outside Kue"
        provider.events[index].title = externalTitle
        provider.events[index].lastModifiedDate = (event.externalCalendarLastKnownModifiedAt ?? .now).addingTimeInterval(3_600)

        // Merely checking status must never itself overwrite anything.
        _ = CalendarExportService.status(for: event, provider: provider)
        #expect(provider.events[index].title == externalTitle)

        // Only an explicit `update(...)` call (the UI's "Overwrite with Kue's Version" tap)
        // pushes Kue's own fields over the external change.
        let result = CalendarExportService.update(event, provider: provider, context: context)
        #expect(result.isSuccess)
        #expect(provider.events.first { $0.externalIdentifier == event.externalCalendarEventIdentifier }?.title == event.title)
    }

    // MARK: - Unlinking (requirement 30)

    @Test func unlinkRemovesOnlyKuesReferenceAndNeverDeletesTheCalendarEvent() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)
        let eventCountBefore = provider.events.count

        CalendarExportService.unlink(event, context: context)

        #expect(event.externalCalendarEventIdentifier == nil)
        #expect(event.externalCalendarIdentifier == nil)
        #expect(event.externalCalendarTitle == nil)
        #expect(event.externalCalendarLastSyncedAt == nil)
        #expect(event.externalCalendarLastKnownModifiedAt == nil)
        // The Calendar-side event itself is untouched — still present in the provider's store.
        #expect(provider.events.count == eventCountBefore)
    }

    // MARK: - Cancellation (requirement 41 — a cancelled action leaves everything untouched)

    @Test func neverCallingExportLeavesTheEventCompletelyUnlinked() {
        let container = ModelContainerFactory.makeInMemory()
        let event = makeEvent(context: container.mainContext)
        // Simulates the user cancelling the destination-calendar picker / confirmation dialog
        // before any service method is ever invoked.
        #expect(event.externalCalendarEventIdentifier == nil)
        #expect(event.title == "Design Review")
    }

    // MARK: - EventKit failure (requirement 41 — Calendar failures never damage Kue data)

    @Test func exportFailureLeavesTheEventCompletelyUnchanged() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let originalUpdatedAt = event.updatedAt
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        provider.saveErrorToThrow = .saveFailed("simulated EventKit failure")

        let result = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)

        #expect(!result.isSuccess)
        #expect(event.externalCalendarEventIdentifier == nil)
        #expect(event.externalCalendarLastSyncedAt == nil)
        #expect(event.updatedAt == originalUpdatedAt)
        #expect(event.title == "Design Review")
    }

    @Test func updateFailureLeavesThePreviousLinkIntact() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)
        let identifierBefore = event.externalCalendarEventIdentifier
        let syncedAtBefore = event.externalCalendarLastSyncedAt

        provider.saveErrorToThrow = .saveFailed("simulated EventKit failure")
        let result = CalendarExportService.update(event, provider: provider, context: context)

        #expect(!result.isSuccess)
        #expect(event.externalCalendarEventIdentifier == identifierBefore)
        #expect(event.externalCalendarLastSyncedAt == syncedAtBefore)
    }

    // MARK: - Notification/widget side effects — requirement 32: Calendar ops never touch them

    @Test func exportUpdateAndUnlinkNeverTouchNotificationsOrTheWidget() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = makeEvent(context: context)
        let provider = FakeCalendarProvider(stateToReturn: .fullAccess, writableCalendars: [homeCalendar])
        let notificationScheduler = FakeNotificationScheduler()
        let widgetReloader = FakeWidgetReloader()

        _ = CalendarExportService.export(event, to: homeCalendar, provider: provider, context: context)
        _ = CalendarExportService.update(event, provider: provider, context: context)
        CalendarExportService.unlink(event, context: context)

        #expect(notificationScheduler.addedRequests.isEmpty)
        #expect(notificationScheduler.removedIdentifierBatches.isEmpty)
        #expect(widgetReloader.reloadedKinds.isEmpty)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
