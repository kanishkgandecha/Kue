//
//  CalendarAuthorizationTests.swift
//  KueTests
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration, requirement 41: every authorization state,
//  permission-request behavior, and "no access before contextual consent." Uses
//  `FakeCalendarProvider` exclusively — never touches `EKEventStore`/real Calendar data.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct CalendarAuthorizationTests {
    // MARK: - Every authorization state (requirement 4/41)

    @Test(arguments: [
        CalendarAuthorizationState.notDetermined,
        .fullAccess,
        .writeOnly,
        .denied,
        .restricted,
        .unavailable,
        .unknown,
    ])
    func everyAuthorizationStateIsReportedDistinctly(_ state: CalendarAuthorizationState) {
        let provider = FakeCalendarProvider(stateToReturn: state)
        #expect(provider.authorizationState() == state)
    }

    @Test func onlyFullAccessCanReadEvents() {
        #expect(CalendarAuthorizationState.fullAccess.canReadEvents)
        #expect(!CalendarAuthorizationState.writeOnly.canReadEvents)
        #expect(!CalendarAuthorizationState.denied.canReadEvents)
        #expect(!CalendarAuthorizationState.notDetermined.canReadEvents)
    }

    @Test func fullAndWriteOnlyAccessCanWriteEvents() {
        #expect(CalendarAuthorizationState.fullAccess.canWriteEvents)
        #expect(CalendarAuthorizationState.writeOnly.canWriteEvents)
        #expect(!CalendarAuthorizationState.denied.canWriteEvents)
        #expect(!CalendarAuthorizationState.restricted.canWriteEvents)
    }

    @Test func everyStateExceptFullAccessHasAnExplanation() {
        for state: CalendarAuthorizationState in [.notDetermined, .writeOnly, .denied, .restricted, .unavailable, .unknown] {
            #expect(state.explanation != nil)
        }
        #expect(CalendarAuthorizationState.fullAccess.explanation == nil)
    }

    // MARK: - Permission-request behavior (requirement 41)

    @Test func requestAccessReturnsTheConfiguredResultAndUpdatesState() async {
        let provider = FakeCalendarProvider(stateToReturn: .notDetermined, requestAccessResult: .fullAccess)
        let result = await provider.requestAccess()
        #expect(result == .fullAccess)
        #expect(provider.authorizationState() == .fullAccess)
        #expect(provider.requestAccessCallCount == 1)
    }

    @Test func requestAccessCanResultInDenial() async {
        let provider = FakeCalendarProvider(stateToReturn: .notDetermined, requestAccessResult: .denied)
        let result = await provider.requestAccess()
        #expect(result == .denied)
    }

    // MARK: - No access before contextual consent (requirement 6/41)

    @Test func authorizationStateNeverCallsRequestAccessItself() {
        // A pure state read never mutates `requestAccessCallCount` — confirms
        // `authorizationState()` cannot itself be the thing that triggers a system prompt.
        let provider = FakeCalendarProvider(stateToReturn: .notDetermined)
        _ = provider.authorizationState()
        _ = provider.authorizationState()
        #expect(provider.requestAccessCallCount == 0)
    }

    @Test func fetchingOrSavingBeforeAccessIsGrantedNeverImplicitlyRequestsIt() async {
        let provider = FakeCalendarProvider(stateToReturn: .notDetermined)
        _ = provider.fetchEvents(from: .now, to: .now.addingTimeInterval(86_400))
        _ = provider.fetchEvent(externalIdentifier: "anything")
        #expect(throws: CalendarOperationError.self) {
            try provider.save(
                KueCalendarEvent(externalIdentifier: "x", calendarIdentifier: "cal", calendarTitle: "Cal", title: "T", startDate: .now, endDate: .now, isAllDay: false, location: nil, notes: nil, timeZoneIdentifier: nil, lastModifiedDate: nil, recurrence: nil),
                in: "cal"
            )
        }
        #expect(provider.requestAccessCallCount == 0)
    }

    @Test func readingWhileWriteOnlyReturnsNothingRatherThanThrowing() {
        let provider = FakeCalendarProvider(stateToReturn: .writeOnly)
        #expect(provider.fetchEvents(from: .now, to: .now.addingTimeInterval(86_400)).isEmpty)
        #expect(provider.fetchEvent(externalIdentifier: "anything") == nil)
    }
}
