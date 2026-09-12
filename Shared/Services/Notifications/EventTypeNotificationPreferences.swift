//
//  EventTypeNotificationPreferences.swift
//  Kue
//
//  Kue 3.0 Phase 7 — docs/35 "Rule model, scopes." The new middle scope in the precedence chain
//  `Specific Event > Event Type > Global Default`. Per-device App Group `UserDefaults`, the
//  exact same storage shape `NotificationGlobalPreferences` already establishes — deliberately
//  **not** a SwiftData model: an event-type rule has no owning event/task row to attach to
//  (`NotificationRuleValidator` requires exactly one of the two), and, like every other
//  Notification Studio preference, it's a *setting*, not synced content — see this file's own
//  "Sync" note below.
//
//  Reuses `NotificationRuleDefault` (Shared/Models/NotificationRuleDefault.swift) as the stored
//  shape for one event-type's own rule list, rather than inventing a fourth near-identical
//  value type — that type is already exactly "a rule with no live event/task owner, validated
//  the same way a real `NotificationRule` is" (its own header), which is exactly what an
//  event-type default is too. `TemplateNotificationDefault`'s own anchor subset (no `.absolute`,
//  no `.taskDue` — a type has no live task to anchor to) is the correct subset here as well.
//
//  **Sync**: deliberately per-device only, never uploaded to Supabase — every other
//  Notification Studio preference (master toggle, quiet hours, sound, privacy...) already
//  established this exact "settings live on-device, only per-event/task `NotificationRule` rows
//  sync" boundary (docs/31 "Per-device behavior"); adding a new synced table for this one
//  additional preference would be new architecture the spec's own governing instruction framed
//  as conditional ("if the rules must sync... extend the existing Supabase system"), not a
//  requirement — see docs/35 for the full disclosed reasoning.
//
//  **Migration**: a brand-new preference — there is no pre-Phase-7 event-type behavior to
//  preserve, so an install that has never opened the new Event Type section simply has an empty
//  `rulesByType`, meaning "no event-type overrides, defer entirely to Global Default" — the
//  exact same "absence means inherit" contract `NotificationRule`'s own header already
//  establishes for event/task-level rows.
//

import Foundation

nonisolated struct EventTypeNotificationPreferences: Codable, Equatable {
    var rulesByType: [EventType: [NotificationRuleDefault]]

    static let empty = EventTypeNotificationPreferences(rulesByType: [:])

    func rules(for eventType: EventType) -> [NotificationRuleDefault] {
        rulesByType[eventType] ?? []
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }
    private static let storageKey = "notificationStudio.eventTypePreferences.v1"

    static var current: EventTypeNotificationPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(EventTypeNotificationPreferences.self, from: data)
        else { return .empty }
        return decoded
    }

    static func save(_ preferences: EventTypeNotificationPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
