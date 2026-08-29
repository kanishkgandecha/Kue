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
    /// Post-Phase-12 fix — the app-managed Lock Screen selection's own resolution, used only
    /// for `.accessoryCircular`/`.accessoryRectangular`/`.accessoryInline` (`context.family`
    /// in `timeline(for:in:)`/`snapshot(for:in:)` below). `.systemSmall`/`.systemMedium`/
    /// `.systemLarge` never produce this case — they keep the existing `.event`/
    /// `.noEligibleEvent` configured-with-Next-Up-fallback behavior entirely unchanged.
    case lockScreen(LockScreenWidgetResolution)
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
        return currentEntry(for: configuration, family: context.family, now: .now)
    }

    func timeline(for configuration: KueWidgetConfigurationIntent, in context: Context) async -> Timeline<KueWidgetEntry> {
        // Post-Phase-12 fix — Lock Screen accessory families are app-managed selection
        // (`LockScreenEventSelection`), entirely independent of `configuration.eventID`/Next
        // Up. `.systemSmall`/`.systemMedium`/`.systemLarge` fall through to the existing
        // configured-with-fallback timeline unchanged.
        if isLockScreenAccessoryFamily(context.family) {
            return lockScreenTimeline(now: .now)
        }

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

    private func currentEntry(for configuration: KueWidgetConfigurationIntent, family: WidgetFamily, now: Date) -> KueWidgetEntry {
        if isLockScreenAccessoryFamily(family) {
            return lockScreenEntry(now: now)
        }
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

    // MARK: - Lock Screen accessory selection (post-Phase-12 fix)

    private func isLockScreenAccessoryFamily(_ family: WidgetFamily) -> Bool {
        family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
    }

    private func lockScreenEntry(now: Date) -> KueWidgetEntry {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            return KueWidgetEntry(date: now, content: .storeUnavailable)
        }
        let modelContext = ModelContext(container)
        let selectedID = LockScreenEventSelection.current
        let event = LockScreenWidgetContentService.resolveSelectedEvent(selectedEventID: selectedID, context: modelContext)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: selectedID != nil, now: now)
        return KueWidgetEntry(date: now, content: .lockScreen(resolution))
    }

    private func lockScreenTimeline(now: Date) -> Timeline<KueWidgetEntry> {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            return Timeline(entries: [KueWidgetEntry(date: now, content: .storeUnavailable)], policy: .after(now.addingTimeInterval(15 * 60)))
        }
        let modelContext = ModelContext(container)
        let selectedID = LockScreenEventSelection.current
        let event = LockScreenWidgetContentService.resolveSelectedEvent(selectedEventID: selectedID, context: modelContext)
        let resolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: selectedID != nil, now: now)

        guard case .tracking = resolution else {
            // Nothing date-driven to precompute for a cancelled/skipped/unselected/unavailable
            // state — it only changes via an explicit app-side action, which already reloads
            // this widget kind's timelines itself (`LockScreenEventSelectionView`). This
            // periodic recheck is only a safety net.
            return Timeline(entries: [KueWidgetEntry(date: now, content: .lockScreen(resolution))], policy: .after(now.addingTimeInterval(15 * 60)))
        }

        var entries = [KueWidgetEntry(date: now, content: .lockScreen(resolution))]
        if let event {
            for transition in WidgetContentService.transitionPlan(for: event, now: now) {
                let transitionResolution = LockScreenWidgetContentService.resolve(event: event, hasStoredSelection: true, now: transition.date)
                entries.append(KueWidgetEntry(date: transition.date, content: .lockScreen(transitionResolution)))
            }
        }
        let policy: TimelineReloadPolicy = entries.count > 1 ? .after(entries.last!.date) : .after(now.addingTimeInterval(15 * 60))
        return Timeline(entries: entries, policy: policy)
    }

    /// A configured instance is an explicit user choice and therefore resolves independently
    /// of the automatic Next-Up `isEnabled` gate. An unconfigured (or deleted/skipped)
    /// selection still falls back to Next Up, preserving this widget kind's existing policy.
    private func resolveEvent(for configuration: KueWidgetConfigurationIntent, context: ModelContext) -> KueEvent? {
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []

        // Kue 2.0 Phase 3: a configured selection that's since been skipped is "unavailable"
        // the same way a disabled/deleted one already was — fall back to "Next Up" instead of
        // showing a skipped occurrence's stale content (docs/17-recurring-events.md "Downstream
        // consumers").
        if let selectedIDString = configuration.eventID,
           let selectedID = UUID(uuidString: selectedIDString),
           let selected = events.first(where: { $0.id == selectedID }),
           !selected.isSkipped {
            return selected
        }
        return WidgetContentService.nextUpEvent(from: events)
    }
}
