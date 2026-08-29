//
//  ShowTodaysEventsIntent.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "B.14/D." — reuses
//  `EventResolutionService.todaysEvents`, the same pinned-timezone day-bucketing
//  `HomeTimelineGrouping` already uses, so "today" here can't disagree with what Home's own
//  Today section shows. Opens Home via `kue://today`. Read-only, no confirmation.
//

import AppIntents
import SwiftData
import Foundation

struct ShowTodaysEventsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Today's Events in Kue"
    static var description = IntentDescription("Shows today's events in Kue.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let context = try KueIntentSupport.makeContext()
        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let todays = EventResolutionService.todaysEvents(in: allEvents)
        KueIntentSupport.openDeepLink(KueDeepLink.url(for: .today))

        guard !todays.isEmpty else {
            return .result(value: [], dialog: "Nothing on your Kue calendar today.")
        }
        let titles = todays.map(\.title)
        let spoken = titles.count == 1 ? "Today in Kue: \(titles[0])." : "Today in Kue: \(titles.joined(separator: ", "))."
        return .result(value: titles, dialog: IntentDialog(stringLiteral: spoken))
    }
}
