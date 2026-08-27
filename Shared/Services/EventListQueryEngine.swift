//
//  EventListQueryEngine.swift
//  Kue
//
//  Kue 2.0 Phase 2 — Search and Event Organization. Pure, SwiftData-free (same split as
//  EventStatusEngine/SchedulingEngine's own "plan first, touch the model graph second"):
//  everything here takes an already-fetched `[KueEvent]` and plain values, never owns a
//  fetch or a ModelContext, so it's testable with in-memory fixtures exactly like every
//  other Services/ file. Lives in Shared/ (not Kue/) because both HomeView (app) and any
//  future widget-side list surface could reuse it, same rationale as WidgetContentService.
//
//  See docs/16-search-and-organization.md for the full search/filter/sort/tie-break policy
//  this file implements.
//

import Foundation

/// Case- and diacritic-insensitive text normalization for local search. A fixed locale
/// (`en_US_POSIX`, Apple's own recommended "no surprises" locale for
/// string-comparison-that-must-not-vary-by-region) keeps folding deterministic across
/// devices/simulators regardless of the user's actual locale — requirement: "deterministic."
enum EventSearchNormalizer {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: comparisonLocale)
    }
}

enum EventListQueryEngine {
    /// Which archived/current events are eligible at all — independent of, and applied
    /// before, `statuses` below (requirement 3: "archived versus current events" is its own
    /// filter axis, not folded into lifecycle/status). Mirrors `event.status == .archived`,
    /// the same persisted-field check `HomeView.visibleEvents`/`DuplicateDetectionService`
    /// already use — `EventStatusEngine.derive(for:)` never produces `.archived` itself (it's
    /// a terminal override set only by `EventActions.archive`), so this can't be folded into
    /// a derived-status comparison the way `statuses` below is.
    /// `nonisolated` for the same reason `Filter` below is — held inside a `nonisolated`
    /// `Equatable` struct, so its own conformance must be usable off the main actor too.
    nonisolated enum ArchivedScope: Equatable {
        case currentOnly
        case archivedOnly
        case all
    }

    /// `nonisolated` — a plain, `Equatable`-compared value type held in `@State`, same reason
    /// `SchedulingEngine.ScheduledTaskPlan`/`NotificationCandidate` are marked this way (see
    /// AGENTS.md's concurrency note): Swift Testing's `#expect` runs off the main actor, and
    /// this module defaults new types to `@MainActor`.
    nonisolated struct Filter: Equatable {
        var eventTypes: Set<EventType> = []
        var statuses: Set<EventStatus> = []
        var archivedScope: ArchivedScope = .currentOnly

        /// The exact filter Home starts with — empty type/status restriction, current
        /// (non-archived) events only. Requirement 7: default filtering/sorting must
        /// reproduce Home's existing Upcoming/Active/Completed sections exactly.
        static let `default` = Filter()
    }

    nonisolated enum SortOption: String, CaseIterable, Identifiable {
        case date
        case priority
        case recentlyModified

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .date: return "Event Date"
            case .priority: return "Priority"
            case .recentlyModified: return "Recently Modified"
            }
        }

        /// The default sort — matches `HomeView`'s existing `@Query(sort: \KueEvent.startDate)`.
        static let `default` = SortOption.date
    }

    /// Requirement 8: distinguish "an empty database," "no results for the current query,"
    /// and "no results for the selected filters" — three different messages, not one generic
    /// empty state. `notEmpty` is never actually shown by a caller (results exist), but is
    /// kept explicit so `emptyReason` is a total function with no silent "should never
    /// happen" branch.
    nonisolated enum EmptyResultReason: Equatable {
        case emptyDatabase
        case noResultsForQuery
        case noResultsForFilters
        case notEmpty
    }

    // MARK: - Matching

    static func matchesFilter(_ event: KueEvent, filter: Filter, now: Date = .now) -> Bool {
        switch filter.archivedScope {
        case .currentOnly:
            if event.status == .archived { return false }
        case .archivedOnly:
            if event.status != .archived { return false }
        case .all:
            break
        }

        if !filter.eventTypes.isEmpty, !filter.eventTypes.contains(event.eventType) {
            return false
        }

        if !filter.statuses.isEmpty {
            // Reconciliation rule 1 (docs/04-event-types.md): recompute live rather than
            // trust a possibly-stale persisted `status`, except archive, which `derive`
            // never produces on its own — same exception `HomeView.bucket(for:)` makes.
            let liveStatus = event.status == .archived ? .archived : EventStatusEngine.derive(for: event, now: now)
            if !filter.statuses.contains(liveStatus) { return false }
        }

        return true
    }

    /// Title, location, notes, and the event type's display name — requirement 1's exact
    /// field list. `normalizedQuery` is expected to already be folded via
    /// `EventSearchNormalizer.normalize` (callers below do this once per call rather than
    /// once per event).
    static func matchesQuery(_ event: KueEvent, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        let haystacks: [String] = [event.title, event.location, event.notes, event.eventType.displayName]
            .compactMap { $0 }
        return haystacks.contains { EventSearchNormalizer.normalize($0).contains(normalizedQuery) }
    }

    // MARK: - Sorting (requirement 5: deterministic tie-breaking for equal sort values)

    /// Every option's primary key ties are broken the same way: normalized title, then
    /// (still-tied, e.g. identical duplicated titles) `id.uuidString`, which is unique per
    /// event and never changes — a total, stable order regardless of input array order or
    /// how many events share a primary key.
    static func sorted(_ events: [KueEvent], by option: SortOption) -> [KueEvent] {
        events.sorted { lhs, rhs in isOrderedBefore(lhs, rhs, option: option) }
    }

    private static func isOrderedBefore(_ lhs: KueEvent, _ rhs: KueEvent, option: SortOption) -> Bool {
        let primary = primaryComparison(lhs, rhs, option: option)
        if primary != 0 { return primary < 0 }

        let lhsTitle = EventSearchNormalizer.normalize(lhs.title)
        let rhsTitle = EventSearchNormalizer.normalize(rhs.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// -1 (lhs first), 0 (tied), 1 (rhs first).
    private static func primaryComparison(_ lhs: KueEvent, _ rhs: KueEvent, option: SortOption) -> Int {
        switch option {
        case .date:
            return compare(lhs.startDate, rhs.startDate)
        case .priority:
            // High first — priorityRank is ascending severity, so a plain ascending compare
            // already puts high (0) before medium (1) before low (2).
            return compare(priorityRank(lhs.priority), priorityRank(rhs.priority))
        case .recentlyModified:
            // Most-recently-modified first, so this is the one descending primary key —
            // achieved by swapping the compare operands rather than the tie-break direction.
            return compare(rhs.updatedAt, lhs.updatedAt)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }

    private static func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    // MARK: - Top-level query

    /// The full pipeline a search/filter/sort-aware list surface needs: filter, then search,
    /// then sort. Filtering before searching (rather than the reverse) is an optimization
    /// only — the two are independent predicates, so the result is identical either order.
    static func query(events: [KueEvent], searchText: String, filter: Filter, sort: SortOption, now: Date = .now) -> [KueEvent] {
        let normalizedQuery = EventSearchNormalizer.normalize(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        let matched = events.filter {
            matchesFilter($0, filter: filter, now: now) && matchesQuery($0, normalizedQuery: normalizedQuery)
        }
        return sorted(matched, by: sort)
    }

    /// Requirement 8. `allEvents` should be the *unfiltered* fetch (every event in the
    /// store, archived included) — `.emptyDatabase` means the store itself has zero rows,
    /// not zero rows visible under the current scope. Precedence when both the query and the
    /// filters would independently produce zero results: filters are checked first, since
    /// "no events match these filters" is true regardless of what's typed in search, while
    /// "no results for this query" is only meaningful once the filtered set is known to be
    /// non-empty.
    static func emptyReason(allEvents: [KueEvent], searchText: String, filter: Filter, now: Date = .now) -> EmptyResultReason {
        if allEvents.isEmpty { return .emptyDatabase }

        let filterOnly = allEvents.filter { matchesFilter($0, filter: filter, now: now) }
        if filterOnly.isEmpty { return .noResultsForFilters }

        let normalizedQuery = EventSearchNormalizer.normalize(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return .notEmpty }

        let withQuery = filterOnly.filter { matchesQuery($0, normalizedQuery: normalizedQuery) }
        return withQuery.isEmpty ? .noResultsForQuery : .notEmpty
    }
}
