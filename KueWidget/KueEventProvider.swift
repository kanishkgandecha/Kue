//
//  KueEventProvider.swift
//  KueWidget
//
//  Thin WidgetKit adapter over WidgetContentService (Shared/) — this file owns no phase
//  math of its own. Timeline reload points come from
//  WidgetContentService.transitionPlan(...), never a fixed polling interval — see
//  docs/07-widget-engine.md "Refresh strategy".
//

import WidgetKit
import SwiftData
import Foundation

enum KueWidgetEntryContent: Equatable {
    case event(WidgetDisplayContent)
    /// No `isEnabled` event is currently upcoming/preparing/tomorrow/today/active.
    case noEligibleEvent
    /// docs/13-error-handling.md "Widget refresh failure" — the shared store couldn't be
    /// opened at all; never surface a raw error to the widget surface itself.
    case storeUnavailable
}

struct KueWidgetEntry: TimelineEntry {
    let date: Date
    let content: KueWidgetEntryContent
}

struct KueEventProvider: AppIntentTimelineProvider {
    typealias Entry = KueWidgetEntry
    typealias Intent = KueWidgetConfigurationIntent

    /// Static, store-free — shown instantly while the real snapshot loads, and in the
    /// widget gallery preview.
    func placeholder(in context: Context) -> KueWidgetEntry {
        KueWidgetEntry(
            date: .now,
            content: .event(WidgetDisplayContent(
                eventID: UUID(),
                eventTitle: "Interview",
                eventTypeDisplayName: "Interview",
                widgetType: .countdown,
                phase: .countdown,
                isUrgent: false,
                headline: "Interview",
                subline: "3 days",
                tasksCompleted: 0,
                tasksTotal: 0,
                tasks: [],
                canSnooze: false
            ))
        )
    }

    func snapshot(for configuration: KueWidgetConfigurationIntent, in context: Context) async -> KueWidgetEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return currentEntry(for: configuration, now: .now)
    }

    func timeline(for configuration: KueWidgetConfigurationIntent, in context: Context) async -> Timeline<KueWidgetEntry> {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            return Timeline(entries: [KueWidgetEntry(date: .now, content: .storeUnavailable)], policy: .after(.now.addingTimeInterval(15 * 60)))
        }
        let modelContext = ModelContext(container)

        guard let event = resolveEvent(for: configuration, context: modelContext) else {
            // No selection (or nothing eligible) — re-check periodically, since "Next Up"
            // can change as soon as any event becomes eligible.
            return Timeline(entries: [KueWidgetEntry(date: .now, content: .noEligibleEvent)], policy: .after(.now.addingTimeInterval(15 * 60)))
        }

        let now = Date.now
        var entries = [KueWidgetEntry(
            date: now,
            content: .event(WidgetContentService.displayContent(
                for: event,
                phase: WidgetContentService.currentPhase(for: event, now: now),
                now: now
            ))
        )]
        for transition in WidgetContentService.transitionPlan(for: event, now: now) {
            entries.append(KueWidgetEntry(
                date: transition.date,
                content: .event(WidgetContentService.displayContent(for: event, phase: transition.phase, now: transition.date))
            ))
        }

        // Precomputed transitions cover everything meaningful for this event; once they're
        // exhausted, ask again rather than assuming (e.g. the user may have picked a new
        // event, or "Next Up" may have changed).
        let policy: TimelineReloadPolicy = entries.count > 1 ? .after(entries.last!.date) : .after(now.addingTimeInterval(15 * 60))
        return Timeline(entries: entries, policy: policy)
    }

    private func currentEntry(for configuration: KueWidgetConfigurationIntent, now: Date) -> KueWidgetEntry {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            return KueWidgetEntry(date: now, content: .storeUnavailable)
        }
        let modelContext = ModelContext(container)
        guard let event = resolveEvent(for: configuration, context: modelContext) else {
            return KueWidgetEntry(date: now, content: .noEligibleEvent)
        }
        return KueWidgetEntry(
            date: now,
            content: .event(WidgetContentService.displayContent(for: event, phase: WidgetContentService.currentPhase(for: event, now: now), now: now))
        )
    }

    /// docs/07-widget-engine.md "Widget instances vs. event eligibility" — a configured
    /// instance shows its picked event (if it's still `isEnabled`); an unconfigured one
    /// falls back to "Next Up".
    private func resolveEvent(for configuration: KueWidgetConfigurationIntent, context: ModelContext) -> KueEvent? {
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []

        // Kue 2.0 Phase 3: a configured selection that's since been skipped is "unavailable"
        // the same way a disabled/deleted one already was — fall back to "Next Up" instead of
        // showing a skipped occurrence's stale content (docs/17-recurring-events.md "Downstream
        // consumers").
        if let selectedID = configuration.event?.id,
           let selected = events.first(where: { $0.id == selectedID }),
           selected.widgetConfiguration?.isEnabled == true, !selected.isSkipped {
            return selected
        }
        return WidgetContentService.nextUpEvent(from: events)
    }
}
