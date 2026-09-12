//
//  NotificationDefaultsApplier.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Notification hierarchy": "Changing
//  global defaults affects newly created events by default. For existing events, provide an
//  explicit operation... Before applying: show how many events will change, show a summary of
//  additions/removals, preserve event-specific overrides, require confirmation, make the
//  operation deterministic and testable. Do not silently rewrite existing events."
//
//  Architecture note: this planner's own inheritance is *live* — an event with no
//  `NotificationRule` override already follows whatever `NotificationGlobalPreferences` says
//  right now, automatically, with no snapshot step (see `NotificationPlanner.swift`'s own
//  header: "the absence of a row means inherit," not "inherit the value that was live at
//  creation time"). So this operation's real effect is **pinning today's global defaults onto
//  existing events as concrete, explicit rules** — after applying, those events stop silently
//  following *future* global-default changes for the anchors this touched, exactly like an
//  event a user has already customized by hand. Events that already carry an explicit
//  event-start or outcome-follow-up rule are always left untouched, unconditionally.
//

import Foundation
import SwiftData

nonisolated struct NotificationDefaultsApplyPreview: Equatable {
    var affectedEventCount: Int
    var eventStartRulesToAdd: Int
    var outcomeFollowUpRulesToAdd: Int
    /// Existing overrides this operation will leave completely untouched — preservation is
    /// per-anchor: an event that already customized its event-start reminder can still gain a
    /// *separate* default outcome-follow-up if it never touched that anchor, without its
    /// event-start override ever being overwritten or duplicated.
    var existingOverridesPreserved: Int
}

enum NotificationDefaultsApplier {
    /// Pure — never touches SwiftData. `events` should be every non-terminal event the caller
    /// wants considered (typically every event in the store).
    static func preview(events: [KueEvent], defaults: NotificationGlobalPreferences) -> NotificationDefaultsApplyPreview {
        var affected = 0
        var eventStartAdds = 0
        var outcomeAdds = 0
        var preserved = 0

        for event in events {
            let hasEventStartOverride = event.notificationRules.contains { $0.anchor == .eventStart }
            let hasOutcomeOverride = event.notificationRules.contains { $0.anchor == .outcomeFollowUp }
            var eventChanged = false

            if !hasEventStartOverride, let minutes = defaults.defaultPreEventMinutes, minutes > 0 {
                eventStartAdds += 1
                eventChanged = true
            } else if hasEventStartOverride {
                preserved += 1
            }
            if !hasOutcomeOverride, defaults.defaultOutcomeFollowUpEnabled {
                outcomeAdds += 1
                eventChanged = true
            } else if hasOutcomeOverride {
                preserved += 1
            }
            if eventChanged { affected += 1 }
        }

        return NotificationDefaultsApplyPreview(
            affectedEventCount: affected, eventStartRulesToAdd: eventStartAdds,
            outcomeFollowUpRulesToAdd: outcomeAdds, existingOverridesPreserved: preserved
        )
    }

    /// Only ever called after the caller has shown `preview(...)` and the user explicitly
    /// confirmed — never invoked as a side effect of merely changing a global default.
    /// Deterministic: given the same `events`/`defaults`, produces the same resulting rules
    /// every time (no random ids affect behavior, only identity — see the accompanying test).
    @discardableResult
    static func apply(events: [KueEvent], defaults: NotificationGlobalPreferences, context: ModelContext, now: Date = .now) -> Int {
        var changed = 0
        for event in events {
            let hasEventStartOverride = event.notificationRules.contains { $0.anchor == .eventStart }
            let hasOutcomeOverride = event.notificationRules.contains { $0.anchor == .outcomeFollowUp }
            var eventChanged = false

            if !hasEventStartOverride, let minutes = defaults.defaultPreEventMinutes, minutes > 0 {
                let rule = NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: minutes, offsetUnit: .minutes, createdAt: now, updatedAt: now)
                context.insert(rule)
                eventChanged = true
            }
            if !hasOutcomeOverride, defaults.defaultOutcomeFollowUpEnabled {
                let rule = NotificationRule(event: event, anchor: .outcomeFollowUp, offsetDirection: .at, offsetQuantity: 0, offsetUnit: .minutes, createdAt: now, updatedAt: now)
                context.insert(rule)
                eventChanged = true
            }
            if eventChanged {
                changed += 1
                // Kue 3.0 Phase 5 — docs/33 "Local outbox": a bulk apply is still one dirty
                // mark per affected event, same as any other notification-rule mutation.
                SyncOutbox.markNotificationRulesDirty(owningEventID: event.id)
            }
        }
        try? context.save()
        return changed
    }
}
