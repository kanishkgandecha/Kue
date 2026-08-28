//
//  DedicatedCountdownProvider.swift
//  KueWidget
//
//  Thin WidgetKit adapter over `DedicatedWidgetContentService` (Shared/) — this file owns no
//  resolution policy of its own beyond "fetch the configured id, hand whatever comes back
//  (including nil) to the strict resolver." See docs/22-expanded-and-dedicated-widgets.md
//  "C."/"D." — this provider has no code path that calls `WidgetContentService.nextUpEvent`.
//
//  Kue 2.0 Phase 9 — section K: the D0–D3 visible diagnostic codes and verbose per-callback
//  Logger tracing added while diagnosing a since-fixed configuration bug (docs/22's own
//  "disproven hypothesis" note) have been removed now that the underlying cause (a broken
//  AppEntity registration, replaced by `KueEventOptionsProvider`'s plain-String selection) is
//  confirmed fixed. Only genuinely useful fault logging remains: the shared store failing to
//  open, or a configured id that no longer resolves to any event.
//

import WidgetKit
import SwiftData
import Foundation
import os

private let dedicatedCountdownLog = Logger(subsystem: "com.kanishkgandecha.Kue.KueWidget", category: "DedicatedCountdown")

enum DedicatedCountdownEntryContent: Equatable {
    case resolved(DedicatedWidgetResolution)
    /// docs/13-error-handling.md "Widget refresh failure" — mirrors
    /// `KueWidgetEntryContent.storeUnavailable`; the store either opens or it doesn't,
    /// independent of which event is configured.
    case storeUnavailable
}

struct DedicatedCountdownEntry: TimelineEntry {
    let date: Date
    let content: DedicatedCountdownEntryContent
}

struct DedicatedCountdownProvider: AppIntentTimelineProvider {
    typealias Entry = DedicatedCountdownEntry
    typealias Intent = DedicatedCountdownConfigurationIntentV3

    /// Static, store-free — shown instantly while the real snapshot loads, and in the widget
    /// gallery preview.
    func placeholder(in context: Context) -> DedicatedCountdownEntry {
        DedicatedCountdownEntry(
            date: .now,
            content: .resolved(.tracking(WidgetDisplayContent(
                eventID: UUID(),
                eventTitle: "CAT 2026",
                eventTypeDisplayName: "Exam",
                widgetType: .countdown,
                phase: .countdown,
                isUrgent: false,
                headline: "CAT 2026",
                subline: "93 days",
                tasksCompleted: 0,
                tasksTotal: 0,
                tasks: [],
                canSnooze: false
            )))
        )
    }

    func snapshot(for configuration: DedicatedCountdownConfigurationIntentV3, in context: Context) async -> DedicatedCountdownEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return currentEntry(for: configuration, now: .now)
    }

    func timeline(for configuration: DedicatedCountdownConfigurationIntentV3, in context: Context) async -> Timeline<DedicatedCountdownEntry> {
        guard configuredEventID(configuration) != nil else {
            let now = Date.now
            return Timeline(
                entries: [DedicatedCountdownEntry(date: now, content: .resolved(.unavailable))],
                policy: .after(now.addingTimeInterval(15 * 60))
            )
        }

        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            dedicatedCountdownLog.fault("timeline: shared store failed to open")
            return Timeline(entries: [DedicatedCountdownEntry(date: .now, content: .storeUnavailable)], policy: .after(.now.addingTimeInterval(15 * 60)))
        }
        let modelContext = ModelContext(container)
        let event = resolveConfiguredEvent(for: configuration, context: modelContext)

        // A terminal (cancelled/skipped/unavailable) state has nothing that will change on
        // its own — re-check periodically in case the user reconfigures via Edit Widget, but
        // don't build a precomputed transition plan for an event that isn't being tracked.
        guard let event else {
            let now = Date.now
            return Timeline(
                entries: [DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: nil, now: now)))],
                policy: .after(now.addingTimeInterval(15 * 60))
            )
        }

        let now = Date.now
        var entries = [DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: event, now: now)))]

        // Cancelled/skipped are absorbing states for this widget (never revert to tracking on
        // their own), so only build the phase-transition timeline while genuinely tracking.
        if case .tracking = DedicatedWidgetContentService.resolve(event: event, now: now) {
            for transition in WidgetContentService.transitionPlan(for: event, now: now) {
                entries.append(DedicatedCountdownEntry(
                    date: transition.date,
                    content: .resolved(.tracking(WidgetContentService.displayContent(for: event, phase: transition.phase, now: transition.date)))
                ))
            }
        }

        let policy: TimelineReloadPolicy = entries.count > 1 ? .after(entries.last!.date) : .after(now.addingTimeInterval(15 * 60))
        return Timeline(entries: entries, policy: policy)
    }

    private func currentEntry(for configuration: DedicatedCountdownConfigurationIntentV3, now: Date) -> DedicatedCountdownEntry {
        guard configuredEventID(configuration) != nil else {
            return DedicatedCountdownEntry(date: now, content: .resolved(.unavailable))
        }
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            return DedicatedCountdownEntry(date: now, content: .storeUnavailable)
        }
        let modelContext = ModelContext(container)
        let event = resolveConfiguredEvent(for: configuration, context: modelContext)
        return DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: event, now: now)))
    }

    /// The *only* lookup this provider performs: does the configured id still resolve to a
    /// real `KueEvent` in the shared store? Nothing here substitutes a different event —
    /// requirement C.5/C.6: "The selected event must never be replaced automatically. Do not
    /// call the automatic 'Next Up' selection path."
    private func resolveConfiguredEvent(for configuration: DedicatedCountdownConfigurationIntentV3, context: ModelContext) -> KueEvent? {
        let selectedID = configuredEventID(configuration)
        let match = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: selectedID, context: context)
        if let selectedID, match == nil {
            _ = selectedID // UUID itself deliberately never logged
            dedicatedCountdownLog.fault("resolveConfiguredEvent: configured event id did not resolve to any event in the shared store")
        }
        return match
    }

    private func configuredEventID(_ configuration: DedicatedCountdownConfigurationIntentV3) -> UUID? {
        configuration.eventID.flatMap(UUID.init(uuidString:))
    }
}
