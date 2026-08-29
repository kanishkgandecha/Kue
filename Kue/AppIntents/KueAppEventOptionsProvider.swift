//
//  KueAppEventOptionsProvider.swift
//  Kue
//
//  The main-app-target equivalent of `KueWidget/KueEventEntity.swift`'s
//  `KueEventOptionsProvider` — same reasoning, reused verbatim: a plain `String` (the event's
//  UUID) backed by a `DynamicOptionsProvider`, never a custom `AppEntity`. See docs/24
//  "E. App entity reliability" for the full investigation this decision is based on — Phase 8
//  hit a real, confirmed WidgetKit `AppEntity` registration failure
//  ("KueEventEntity is not a registered AppEntity identifier"), so every event-referencing
//  parameter in this app, in both targets, uses this same proven mechanism rather than risking
//  a second instance of that failure for an unconfirmed reliability gain.
//
//  Distinct from `KueEventOptionsProvider` (KueWidget/) only in eligibility: intents can
//  reasonably reference *any* current (non-archived) event — including one already completed/
//  cancelled/skipped, since "Restore Event"/"Open Event" need to reach those too — not just the
//  Dedicated-Countdown-eligible subset.
//

import AppIntents
import SwiftData
import Foundation

struct KueAppEventOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let items = referenceableEvents().map { event in
            IntentItem(
                event.id.uuidString,
                title: LocalizedStringResource(stringLiteral: event.title),
                subtitle: LocalizedStringResource(stringLiteral: "\(event.eventType.displayName) · \(SpotlightEventPayloadBuilder.statusLabel(for: event.status == .archived ? .archived : EventStatusEngine.derive(for: event)))")
            )
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }

    private func referenceableEvents() -> [KueEvent] {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<KueEvent>(sortBy: [SortDescriptor(\.startDate)])
        let events = (try? context.fetch(descriptor)) ?? []
        return EventListQueryEngine.sorted(events.filter { $0.status != .archived }, by: .date)
    }
}
