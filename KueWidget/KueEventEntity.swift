//
//  KueEventEntity.swift
//  KueWidget
//
//  The AppEntity/EntityQuery pair backing the widget's configuration picker — see
//  docs/07-widget-engine.md "Widget instances vs. event eligibility". `KueEvent` itself
//  isn't usable as an AppEntity (it's a SwiftData @Model, not a plain Sendable value type),
//  so this is a small value-type projection of just what the picker needs to display.
//

import AppIntents
import SwiftData
import Foundation

struct KueEventEntity: AppEntity, Identifiable {
    let id: UUID
    let title: String
    let eventTypeDisplayName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Event"
    static var defaultQuery = KueEventEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(eventTypeDisplayName)")
    }
}

struct KueEventEntityQuery: EntityQuery {
    func entities(for identifiers: [KueEventEntity.ID]) async throws -> [KueEventEntity] {
        eligibleEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [KueEventEntity] {
        eligibleEntities()
    }

    /// Requirement: picker results include only `WidgetConfiguration.isEnabled == true`
    /// events — no other filter (archived-but-still-enabled events are intentionally left
    /// in; "Next Up" is what applies the status filter, not the picker).
    private func eligibleEntities() -> [KueEventEntity] {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else { return [] }
        let context = ModelContext(container)
        let events = (try? context.fetch(FetchDescriptor<KueEvent>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
        return events
            .filter { $0.widgetConfiguration?.isEnabled == true }
            .map { KueEventEntity(id: $0.id, title: $0.title, eventTypeDisplayName: $0.eventType.displayName) }
    }
}
