//
//  FindEventsIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.3/D." — read-only, no confirmation
//  needed (requirement C: "opening, finding, and showing data should not require unnecessary
//  confirmation"). Reuses `EventResolutionService`/`EventListQueryEngine` verbatim — this
//  intent adds no search rule of its own. Returns a plain `[String]` of matched titles (not a
//  custom `AppEntity`) so a Shortcuts pipeline can consume the result without depending on the
//  entity-registration mechanism Phase 8 found unreliable (docs/24 "E.").
//

import AppIntents
import SwiftData
import Foundation

enum FindEventsScope: String, AppEnum {
    case today
    case upcoming
    case all

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Scope"
    static var caseDisplayRepresentations: [FindEventsScope: DisplayRepresentation] = [
        .today: "Today",
        .upcoming: "Upcoming",
        .all: "All Current",
    ]
}

struct FindEventsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Events in Kue"
    static var description = IntentDescription("Searches your Kue events by title, type, and scope.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search Text", default: nil)
    var query: String?

    @Parameter(title: "Event Type", default: nil)
    var eventType: EventTypeOption?

    @Parameter(title: "Scope", default: .upcoming)
    var scope: FindEventsScope

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$scope) events in Kue") {
            \.$query
            \.$eventType
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []

        var matches: [KueEvent]
        switch scope {
        case .today: matches = EventResolutionService.todaysEvents(in: allEvents)
        case .upcoming: matches = EventResolutionService.upcomingEvents(in: allEvents)
        case .all: matches = EventListQueryEngine.sorted(allEvents.filter { $0.status != .archived }, by: .date)
        }

        if let eventType {
            matches = EventResolutionService.filter(matches, type: eventType.eventType)
        }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = EventSearchNormalizer.normalize(query)
            matches = matches.filter { EventSearchNormalizer.normalize($0.title).contains(normalized) }
        }

        let summaries = matches.map { event in
            "\(event.title) (\(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)))"
        }

        guard !summaries.isEmpty else {
            return .result(value: [], dialog: "No matching events in Kue.")
        }
        let spoken = summaries.count == 1
            ? summaries[0]
            : "\(summaries.count) events: \(summaries.prefix(5).joined(separator: ", "))\(summaries.count > 5 ? ", and more" : "")"
        return .result(value: summaries, dialog: IntentDialog(stringLiteral: spoken))
    }
}
