//
//  ShowNextEventIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.13/D." — "next event" reuses
//  `EventResolutionService.nextEvent` (a pass-through to `WidgetContentService.nextUpEvent`),
//  never a re-derived rule, so this can never disagree with Home/the widget's own "Next Up"
//  pick — and never selects/starts a Dedicated Countdown or Live Activity (requirement B: "must
//  not alter the Dedicated Countdown selection or automatically start a Live Activity"). Opens
//  the event via the same deep link a Spotlight/widget tap already uses. Read-only, no
//  confirmation.
//

import AppIntents
import SwiftData
import Foundation

struct ShowNextEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Next Event in Kue"
    static var description = IntentDescription("Shows your next upcoming event in Kue.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        guard let next = EventResolutionService.nextEvent(in: allEvents) else {
            throw KueIntentError.noUpcomingEvent
        }
        KueIntentSupport.openDeepLink(KueDeepLink.url(for: .event(next.id)))
        let when = next.startDate.formatted(date: .abbreviated, time: next.isAllDay ? .omitted : .shortened)
        return .result(dialog: "Your next event is \"\(next.title)\" on \(when).")
    }
}
