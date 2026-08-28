//
//  KueEventEntity.swift
//  KueWidget
//
//  Dynamic choices for widget configuration. The persisted value is deliberately the event's
//  UUID string rather than an AppEntity: WidgetKit repeatedly failed to register otherwise
//  valid AppEntity metadata at runtime, making configured values deserialize as nil. A String
//  is a native App Intent value and therefore has no entity-registry dependency.
//

import AppIntents
import SwiftData
import Foundation

struct KueEventOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let items = eligibleEvents().map { event in
            IntentItem(
                event.id.uuidString,
                title: LocalizedStringResource(stringLiteral: event.title),
                subtitle: LocalizedStringResource(stringLiteral: event.eventType.displayName)
            )
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }

    private func eligibleEvents() -> [KueEvent] {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<KueEvent>(sortBy: [SortDescriptor(\.startDate)])
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { WidgetContentService.isEligibleForDedicatedSelection($0) }
    }
}
