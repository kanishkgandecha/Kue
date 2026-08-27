//
//  EventListQueryEngineTests.swift
//  KueTests
//
//  Kue 2.0 Phase 2 — requirement 13: search normalization, every filter, every sort, filter
//  combinations, stable tie-breaking. Pure — no ModelContext, plain in-memory `KueEvent`
//  instances (never saved), matching how SchedulingEngineTests/EventStatusEngineTests test
//  their own pure layers.
//

import Testing
import Foundation
@testable import Kue

@MainActor
struct EventListQueryEngineTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeEvent(
        title: String,
        eventType: EventType = .generic,
        startDate: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        priority: Priority = .medium,
        status: EventStatus = .upcoming,
        updatedAt: Date? = nil
    ) -> KueEvent {
        KueEvent(
            title: title,
            eventType: eventType,
            startDate: startDate ?? now.addingTimeInterval(10 * 86_400),
            estimatedDurationMinutes: 60,
            timeZoneIdentifier: "UTC",
            location: location,
            notes: notes,
            source: .manual,
            priority: priority,
            status: status,
            updatedAt: updatedAt ?? now
        )
    }

    // MARK: - Search normalization

    @Test func normalizationIsCaseInsensitive() {
        #expect(EventSearchNormalizer.normalize("Interview") == EventSearchNormalizer.normalize("INTERVIEW"))
    }

    @Test func normalizationIsDiacriticInsensitive() {
        #expect(EventSearchNormalizer.normalize("café") == EventSearchNormalizer.normalize("cafe"))
        #expect(EventSearchNormalizer.normalize("Café Meeting") == EventSearchNormalizer.normalize("CAFE MEETING"))
    }

    @Test func normalizationIsDeterministicAcrossRepeatedCalls() {
        let input = "Résumé Review — Café"
        #expect(EventSearchNormalizer.normalize(input) == EventSearchNormalizer.normalize(input))
    }

    // MARK: - Search fields (requirement 1: title, location, notes, event-type display name)

    @Test func searchMatchesTitle() {
        let event = makeEvent(title: "Quarterly Review")
        #expect(EventListQueryEngine.matchesQuery(event, normalizedQuery: EventSearchNormalizer.normalize("quarterly")))
    }

    @Test func searchMatchesLocationCaseAndDiacriticInsensitively() {
        let event = makeEvent(title: "Team Sync", location: "Café Central")
        #expect(EventListQueryEngine.matchesQuery(event, normalizedQuery: EventSearchNormalizer.normalize("CAFE")))
    }

    @Test func searchMatchesNotes() {
        let event = makeEvent(title: "Standup", notes: "Bring the quarterly numbers")
        #expect(EventListQueryEngine.matchesQuery(event, normalizedQuery: EventSearchNormalizer.normalize("numbers")))
    }

    @Test func searchMatchesEventTypeDisplayName() {
        let event = makeEvent(title: "Something Unrelated", eventType: .interview)
        #expect(EventListQueryEngine.matchesQuery(event, normalizedQuery: EventSearchNormalizer.normalize("interview")))
    }

    @Test func searchWithNoMatchingFieldReturnsFalse() {
        let event = makeEvent(title: "Standup", location: "Room A", notes: "Nothing relevant")
        #expect(!EventListQueryEngine.matchesQuery(event, normalizedQuery: EventSearchNormalizer.normalize("zzz-no-match")))
    }

    @Test func emptyQueryMatchesEverything() {
        let event = makeEvent(title: "Anything")
        #expect(EventListQueryEngine.matchesQuery(event, normalizedQuery: ""))
    }

    // MARK: - Filters (requirement 3)

    @Test func eventTypeFilterKeepsOnlySelectedTypes() {
        let interview = makeEvent(title: "I", eventType: .interview)
        let exam = makeEvent(title: "E", eventType: .exam)
        let filter = EventListQueryEngine.Filter(eventTypes: [.interview])
        #expect(EventListQueryEngine.matchesFilter(interview, filter: filter, now: now))
        #expect(!EventListQueryEngine.matchesFilter(exam, filter: filter, now: now))
    }

    @Test func statusFilterUsesLiveDerivedStatusNotStalePersistedStatus() {
        // Stored as `.upcoming` but its startDate has already passed — derive() says `.completed`.
        let staleEvent = makeEvent(title: "Stale", startDate: now.addingTimeInterval(-3600), status: .upcoming)
        let filter = EventListQueryEngine.Filter(statuses: [.completed])
        #expect(EventListQueryEngine.matchesFilter(staleEvent, filter: filter, now: now))

        let notCompletedFilter = EventListQueryEngine.Filter(statuses: [.upcoming])
        #expect(!EventListQueryEngine.matchesFilter(staleEvent, filter: notCompletedFilter, now: now))
    }

    @Test func archivedScopeCurrentOnlyExcludesArchived() {
        let archived = makeEvent(title: "A", status: .archived)
        let current = makeEvent(title: "C", status: .upcoming)
        let filter = EventListQueryEngine.Filter(archivedScope: .currentOnly)
        #expect(!EventListQueryEngine.matchesFilter(archived, filter: filter, now: now))
        #expect(EventListQueryEngine.matchesFilter(current, filter: filter, now: now))
    }

    @Test func archivedScopeArchivedOnlyExcludesCurrent() {
        let archived = makeEvent(title: "A", status: .archived)
        let current = makeEvent(title: "C", status: .upcoming)
        let filter = EventListQueryEngine.Filter(archivedScope: .archivedOnly)
        #expect(EventListQueryEngine.matchesFilter(archived, filter: filter, now: now))
        #expect(!EventListQueryEngine.matchesFilter(current, filter: filter, now: now))
    }

    @Test func archivedScopeAllIncludesBoth() {
        let archived = makeEvent(title: "A", status: .archived)
        let current = makeEvent(title: "C", status: .upcoming)
        let filter = EventListQueryEngine.Filter(archivedScope: .all)
        #expect(EventListQueryEngine.matchesFilter(archived, filter: filter, now: now))
        #expect(EventListQueryEngine.matchesFilter(current, filter: filter, now: now))
    }

    @Test func defaultFilterMatchesEveryNonArchivedEventRegardlessOfTypeOrStatus() {
        let interview = makeEvent(title: "I", eventType: .interview)
        let exam = makeEvent(title: "E", eventType: .exam, startDate: now.addingTimeInterval(-3600))
        #expect(EventListQueryEngine.matchesFilter(interview, filter: .default, now: now))
        #expect(EventListQueryEngine.matchesFilter(exam, filter: .default, now: now))
    }

    // MARK: - Filter combinations

    @Test func combinedTypeAndStatusFilterRequiresBoth() {
        let matchingBoth = makeEvent(title: "Both", eventType: .interview, startDate: now.addingTimeInterval(10 * 86_400))
        let wrongType = makeEvent(title: "WrongType", eventType: .exam, startDate: now.addingTimeInterval(10 * 86_400))
        let wrongStatus = makeEvent(title: "WrongStatus", eventType: .interview, startDate: now.addingTimeInterval(-3600))

        let filter = EventListQueryEngine.Filter(eventTypes: [.interview], statuses: [.upcoming])
        #expect(EventListQueryEngine.matchesFilter(matchingBoth, filter: filter, now: now))
        #expect(!EventListQueryEngine.matchesFilter(wrongType, filter: filter, now: now))
        #expect(!EventListQueryEngine.matchesFilter(wrongStatus, filter: filter, now: now))
    }

    @Test func queryCombinesSearchAndFilterAsAnIntersection() {
        let events = [
            makeEvent(title: "Interview Prep", eventType: .interview),
            makeEvent(title: "Interview Prep", eventType: .exam),
            makeEvent(title: "Something Else", eventType: .interview),
        ]
        let filter = EventListQueryEngine.Filter(eventTypes: [.interview])
        let results = EventListQueryEngine.query(events: events, searchText: "Interview Prep", filter: filter, sort: .date, now: now)
        #expect(results.count == 1)
        #expect(results.first?.eventType == .interview)
        #expect(results.first?.title == "Interview Prep")
    }

    // MARK: - Sorting (requirement 4/5)

    @Test func sortByDateOrdersAscending() {
        let earlier = makeEvent(title: "Earlier", startDate: now.addingTimeInterval(86_400))
        let later = makeEvent(title: "Later", startDate: now.addingTimeInterval(2 * 86_400))
        let sorted = EventListQueryEngine.sorted([later, earlier], by: .date)
        #expect(sorted.map(\.title) == ["Earlier", "Later"])
    }

    @Test func sortByPriorityOrdersHighFirst() {
        let low = makeEvent(title: "Low", priority: .low)
        let high = makeEvent(title: "High", priority: .high)
        let medium = makeEvent(title: "Medium", priority: .medium)
        let sorted = EventListQueryEngine.sorted([low, medium, high], by: .priority)
        #expect(sorted.map(\.title) == ["High", "Medium", "Low"])
    }

    @Test func sortByRecentlyModifiedOrdersMostRecentFirst() {
        let olderEdit = makeEvent(title: "OlderEdit", updatedAt: now.addingTimeInterval(-3600))
        let recentEdit = makeEvent(title: "RecentEdit", updatedAt: now)
        let sorted = EventListQueryEngine.sorted([olderEdit, recentEdit], by: .recentlyModified)
        #expect(sorted.map(\.title) == ["RecentEdit", "OlderEdit"])
    }

    // MARK: - Stable tie-breaking (requirement 5)

    @Test func equalDatesBreakTiesByNormalizedTitleThenID() {
        let sameDate = now.addingTimeInterval(86_400)
        let bravo = makeEvent(title: "Bravo", startDate: sameDate)
        let alpha = makeEvent(title: "alpha", startDate: sameDate) // lowercase — normalization must still order it first

        let forward = EventListQueryEngine.sorted([bravo, alpha], by: .date)
        let reversed = EventListQueryEngine.sorted([alpha, bravo], by: .date)

        #expect(forward.map(\.title) == ["alpha", "Bravo"])
        #expect(reversed.map(\.title) == ["alpha", "Bravo"])
    }

    @Test func fullyIdenticalPrimaryAndTitleStillProducesAStableOrderViaID() {
        let sameDate = now.addingTimeInterval(86_400)
        let first = makeEvent(title: "Duplicate", startDate: sameDate)
        let second = makeEvent(title: "Duplicate", startDate: sameDate)
        let expectedOrder = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)

        let sortedOnce = EventListQueryEngine.sorted([first, second], by: .date)
        let sortedReversedInput = EventListQueryEngine.sorted([second, first], by: .date)

        #expect(sortedOnce.map(\.id) == expectedOrder)
        #expect(sortedReversedInput.map(\.id) == expectedOrder)
    }

    @Test func tieBreakingIsConsistentForPriorityAndRecentlyModifiedToo() {
        let sameUpdatedAt = now
        let bravo = makeEvent(title: "Bravo", priority: .high, updatedAt: sameUpdatedAt)
        let alpha = makeEvent(title: "Alpha", priority: .high, updatedAt: sameUpdatedAt)

        #expect(EventListQueryEngine.sorted([bravo, alpha], by: .priority).map(\.title) == ["Alpha", "Bravo"])
        #expect(EventListQueryEngine.sorted([bravo, alpha], by: .recentlyModified).map(\.title) == ["Alpha", "Bravo"])
    }

    // MARK: - Empty-state distinctions (requirement 8)

    @Test func emptyReasonIsEmptyDatabaseWhenNoEventsExistAtAll() {
        let reason = EventListQueryEngine.emptyReason(allEvents: [], searchText: "", filter: .default, now: now)
        #expect(reason == .emptyDatabase)
    }

    @Test func emptyReasonIsNoResultsForFiltersWhenFiltersExcludeEverything() {
        let events = [makeEvent(title: "Only Exam", eventType: .exam)]
        let filter = EventListQueryEngine.Filter(eventTypes: [.interview])
        let reason = EventListQueryEngine.emptyReason(allEvents: events, searchText: "", filter: filter, now: now)
        #expect(reason == .noResultsForFilters)
    }

    @Test func emptyReasonIsNoResultsForQueryWhenFiltersPassButSearchDoesNot() {
        let events = [makeEvent(title: "Only Exam", eventType: .exam)]
        let reason = EventListQueryEngine.emptyReason(allEvents: events, searchText: "zzz-nomatch", filter: .default, now: now)
        #expect(reason == .noResultsForQuery)
    }

    @Test func emptyReasonIsNotEmptyWhenSomethingMatches() {
        let events = [makeEvent(title: "Only Exam", eventType: .exam)]
        let reason = EventListQueryEngine.emptyReason(allEvents: events, searchText: "exam", filter: .default, now: now)
        #expect(reason == .notEmpty)
    }

    @Test func emptyReasonPrefersFiltersOverQueryWhenBothWouldFail() {
        let events = [makeEvent(title: "Only Exam", eventType: .exam)]
        let filter = EventListQueryEngine.Filter(eventTypes: [.interview])
        let reason = EventListQueryEngine.emptyReason(allEvents: events, searchText: "zzz-nomatch", filter: filter, now: now)
        #expect(reason == .noResultsForFilters)
    }
}
