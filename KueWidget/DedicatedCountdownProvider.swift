//
//  DedicatedCountdownProvider.swift
//  KueWidget
//
//  Thin WidgetKit adapter over `DedicatedWidgetContentService` (Shared/) — this file owns no
//  resolution policy of its own beyond "fetch the configured id, hand whatever comes back
//  (including nil) to the strict resolver." See docs/22-expanded-and-dedicated-widgets.md
//  "C."/"D." — this provider has no code path that calls `WidgetContentService.nextUpEvent`.
//
//  The privacy-safe fault logging is intentionally retained for genuinely surprising store
//  failures; temporary on-widget diagnostic badges are not part of the product UI.
//

import WidgetKit
import SwiftData
import Foundation
import os

private let dedicatedCountdownLog = Logger(subsystem: "com.kanishkgandecha.Kue.KueWidget", category: "DedicatedCountdown")

/// TEMPORARY — which of the four resolution branches actually produced this entry. Not
/// persisted, not part of `DedicatedWidgetResolution` (Shared/, unchanged) — purely a
/// diagnostic annotation the DEBUG-only view renders as "D0"–"D3".
enum DedicatedCountdownDiagnosticCode: String {
    /// `configuration.event` itself was `nil` when the provider ran.
    case notConfigured = "D0"
    /// `ModelContainerFactory.makeDefaultOrNil()` returned `nil` — the shared store didn't open.
    case storeUnavailable = "D1"
    /// A UUID was configured and the store opened, but no `KueEvent` with that id was found.
    case configuredEventMissing = "D2"
    /// A matching event was found (whatever `DedicatedWidgetResolution` case that maps to —
    /// tracking, cancelled, or skipped all count as "resolved" here; only "found the row or
    /// not" is what this diagnostic distinguishes).
    case resolved = "D3"
}

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
    /// TEMPORARY — see this file's own header. Always populated (cheap, a plain enum), only
    /// ever *rendered* under `#if DEBUG` in `DedicatedCountdownEntryView`.
    let diagnosticCode: DedicatedCountdownDiagnosticCode
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
            ))),
            diagnosticCode: .resolved
        )
    }

    func snapshot(for configuration: DedicatedCountdownConfigurationIntentV3, in context: Context) async -> DedicatedCountdownEntry {
        log(callback: "snapshot", configuration: configuration)
        if context.isPreview {
            return placeholder(in: context)
        }
        return currentEntry(for: configuration, now: .now)
    }

    func timeline(for configuration: DedicatedCountdownConfigurationIntentV3, in context: Context) async -> Timeline<DedicatedCountdownEntry> {
        log(callback: "timeline", configuration: configuration)

        guard configuredEventID(configuration) != nil else {
            let now = Date.now
            return Timeline(
                entries: [DedicatedCountdownEntry(date: now, content: .resolved(.unavailable), diagnosticCode: .notConfigured)],
                policy: .after(now.addingTimeInterval(15 * 60))
            )
        }

        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            dedicatedCountdownLog.notice("[timeline] storeOpened=false")
            dedicatedCountdownLog.fault("timeline: shared store failed to open")
            return Timeline(entries: [DedicatedCountdownEntry(date: .now, content: .storeUnavailable, diagnosticCode: .storeUnavailable)], policy: .after(.now.addingTimeInterval(15 * 60)))
        }
        dedicatedCountdownLog.notice("[timeline] storeOpened=true")
        let modelContext = ModelContext(container)
        let (event, code) = resolveConfiguredEvent(for: configuration, context: modelContext)

        // A terminal (cancelled/skipped/unavailable) state has nothing that will change on
        // its own — re-check periodically in case the user reconfigures via Edit Widget, but
        // don't build a precomputed transition plan for an event that isn't being tracked.
        guard let event else {
            let now = Date.now
            return Timeline(
                entries: [DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: nil, now: now)), diagnosticCode: code)],
                policy: .after(now.addingTimeInterval(15 * 60))
            )
        }

        let now = Date.now
        var entries = [DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: event, now: now)), diagnosticCode: code)]

        // Cancelled/skipped are absorbing states for this widget (never revert to tracking on
        // their own), so only build the phase-transition timeline while genuinely tracking.
        if case .tracking = DedicatedWidgetContentService.resolve(event: event, now: now) {
            for transition in WidgetContentService.transitionPlan(for: event, now: now) {
                entries.append(DedicatedCountdownEntry(
                    date: transition.date,
                    content: .resolved(.tracking(WidgetContentService.displayContent(for: event, phase: transition.phase, now: transition.date))),
                    diagnosticCode: .resolved
                ))
            }
        }

        let policy: TimelineReloadPolicy = entries.count > 1 ? .after(entries.last!.date) : .after(now.addingTimeInterval(15 * 60))
        return Timeline(entries: entries, policy: policy)
    }

    private func currentEntry(for configuration: DedicatedCountdownConfigurationIntentV3, now: Date) -> DedicatedCountdownEntry {
        guard configuredEventID(configuration) != nil else {
            return DedicatedCountdownEntry(date: now, content: .resolved(.unavailable), diagnosticCode: .notConfigured)
        }
        guard let container = ModelContainerFactory.makeDefaultOrNil() else {
            dedicatedCountdownLog.notice("[snapshot] storeOpened=false")
            return DedicatedCountdownEntry(date: now, content: .storeUnavailable, diagnosticCode: .storeUnavailable)
        }
        dedicatedCountdownLog.notice("[snapshot] storeOpened=true")
        let modelContext = ModelContext(container)
        let (event, code) = resolveConfiguredEvent(for: configuration, context: modelContext)
        return DedicatedCountdownEntry(date: now, content: .resolved(DedicatedWidgetContentService.resolve(event: event, now: now)), diagnosticCode: code)
    }

    /// The *only* lookup this provider performs: does the configured id still resolve to a
    /// real `KueEvent` in the shared store? Nothing here substitutes a different event —
    /// requirement C.5/C.6: "The selected event must never be replaced automatically. Do not
    /// call the automatic 'Next Up' selection path." Returns the diagnostic branch alongside
    /// the event so callers never have to re-derive which case applied.
    private func resolveConfiguredEvent(for configuration: DedicatedCountdownConfigurationIntentV3, context: ModelContext) -> (KueEvent?, DedicatedCountdownDiagnosticCode) {
        let selectedID = configuredEventID(configuration)
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let match = DedicatedWidgetContentService.resolveConfiguredEvent(selectedEventID: selectedID, context: context)
        dedicatedCountdownLog.notice("resolveConfiguredEvent: fetchedCount=\(events.count, privacy: .public) idMatched=\(match != nil, privacy: .public)")
        if let selectedID, match == nil {
            dedicatedCountdownLog.fault("resolveConfiguredEvent: configured UUID did not resolve to any event in the shared store (fetchedCount=\(events.count, privacy: .public))")
            _ = selectedID // UUID itself deliberately never logged
            return (nil, .configuredEventMissing)
        }
        return (match, .resolved)
    }

    /// TEMPORARY — requested log shape: snapshot-vs-timeline callback, whether
    /// whether a valid configured event id exists and the widget kind. Never logs
    /// titles/notes/locations/dates/UUID values.
    private func log(callback: String, configuration: DedicatedCountdownConfigurationIntentV3) {
        let idExists = configuredEventID(configuration) != nil
        dedicatedCountdownLog.notice("[\(callback, privacy: .public)] kind=DedicatedCountdown idExists=\(idExists, privacy: .public)")
    }

    private func configuredEventID(_ configuration: DedicatedCountdownConfigurationIntentV3) -> UUID? {
        configuration.eventID.flatMap(UUID.init(uuidString:))
    }
}
