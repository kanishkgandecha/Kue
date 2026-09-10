//
//  PrivacyActions.swift
//  Kue
//
//  See docs/11-privacy-and-offline.md "Privacy principles": "A clear 'delete everything'
//  option — Settings → Privacy must include a single action that deletes all `KueEvent` rows
//  (and their cascading children) and resets `UserPreference` to defaults, with a
//  confirmation step." Genuine V1 gap found during the Phase 10 audit — never implemented in
//  any earlier phase. The confirmation step itself lives in SettingsView (a
//  `.confirmationDialog`); this file is only the actual deletion/reset, kept testable and
//  separate from the SwiftUI trigger the same way every other mutation in this codebase is
//  (EventActions, NotificationEngine, ...).
//

import Foundation
import SwiftData

enum PrivacyActions {
    /// Deletes every `KueEvent` (cascading to its tasks/schedule/widget configuration/widget
    /// state — docs/03-data-model.md "Relationships at a glance"), removes every pending
    /// notification those events could have had, resets `UserPreference` to its declared
    /// defaults, reloads the widget, and saves. Returns whether it actually succeeded — a
    /// failed save leaves the store untouched (rolled back) rather than partially wiped.
    @discardableResult
    static func deleteEverything(
        context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        widgetReloader: WidgetReloading = SystemWidgetReloader.shared,
        liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared,
        spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared,
        now: Date = .now
    ) -> Bool {
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let identifiers = events.flatMap { NotificationCandidateBuilder.allIdentifiers(for: $0) }
        for event in events {
            context.delete(event)
        }

        let preference = UserPreferenceStore.current(context: context)
        preference.notificationIntensity = .standard
        preference.aiParsingEnabled = true

        do {
            try context.save()
        } catch {
            context.rollback()
            return false
        }

        if !identifiers.isEmpty {
            scheduler.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)
        widgetReloader.reloadTimelines(ofKind: WidgetKind.dedicatedCountdown)
        // Kue 2.0 Phase 10 — docs/24 "I.": nothing left to focus or find once every event is
        // gone. `endAll()`'s own doc comment (Phase 9) already names this exact call site as
        // its intended use — never wired in until now.
        Task {
            await liveActivityManager.endAll()
            await spotlightIndexer.removeAll()
        }
        return true
    }
}
