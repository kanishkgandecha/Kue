//
//  RecommendationDismissalStore.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "F. Accept, edit, dismiss, and snooze" / "Dismissal expiry".
//  Persists the *minimum* state needed so a dismissed or snoozed recommendation doesn't
//  immediately reappear — never the recommendation's own content (that's recomputed fresh
//  every time from live events/tasks). App Group `UserDefaults`, same per-device precedent as
//  `SmartPlanningPreferences`/`NotificationGlobalPreferences`.
//
//  **Deterministic expiry** (docs/36): a dismissal is keyed to `PlanningRecommendation.id`,
//  which is itself derived from the fields that produced the recommendation (category,
//  affected IDs, a coarse fingerprint of due/start dates and status). The instant a genuinely
//  new circumstance changes one of those fields, the engine computes a *different* `id` for
//  the "same" underlying event/task, and the old dismissal simply no longer matches anything —
//  no separate content-diffing logic needed. On top of that, every dismissal also carries a
//  hard `suppressUntil` date (see `dismiss(id:now:)`) as a safety net, so even an identical
//  recommendation doesn't stay suppressed forever if the user never revisits it.
//

import Foundation

nonisolated struct RecommendationDismissal: Codable, Equatable {
    /// When this was recorded — kept for the reset-dismissed-suggestions UI to show "how many
    /// / how old," never surfaced as sensitive content.
    var recordedAt: Date
    /// The suppression stops applying at (and after) this date — a plain dismiss uses a fixed
    /// short window (see `dismissWindow`); a snooze uses whatever the user picked.
    var suppressUntil: Date
}

enum RecommendationDismissalStore {
    /// docs/36: a dismissed recommendation shouldn't "immediately reappear," but a stale
    /// dismissal also shouldn't suppress "future genuinely changed circumstances" forever.
    /// Three days covers "I saw this and don't want it today or tomorrow" without silently
    /// hiding something that's still true a week later just because the `id` happened not to
    /// change in the interim (e.g. an overdue task that stays overdue at the same day-bucket
    /// granularity `id` fingerprints at).
    static let dismissWindow: TimeInterval = 3 * 24 * 60 * 60

    private static let defaults = UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    private static let storageKey = "smartPlanning.dismissals.v1"

    private static var all: [String: RecommendationDismissal] {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([String: RecommendationDismissal].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: storageKey)
        }
    }

    static func dismiss(id: String, now: Date = .now) {
        var current = all
        current[id] = RecommendationDismissal(recordedAt: now, suppressUntil: now.addingTimeInterval(dismissWindow))
        all = current
    }

    static func snooze(id: String, until: Date, now: Date = .now) {
        var current = all
        current[id] = RecommendationDismissal(recordedAt: now, suppressUntil: until)
        all = current
    }

    /// True while `id`'s dismissal/snooze is still in effect at `now`. A caller never needs
    /// to prune expired entries itself — this is the single source of truth for "is this
    /// suppressed right now."
    static func isSuppressed(id: String, now: Date = .now) -> Bool {
        guard let record = all[id] else { return false }
        return now < record.suppressUntil
    }

    /// docs/36 "G. Preferences": "reset dismissed suggestions."
    static func resetAll() {
        defaults.removeObject(forKey: storageKey)
    }

    /// Every id still suppressed at `now` — what `SmartPlanningEngineInput.suppressedIDs`
    /// should be populated with before calling `SmartPlanningEngine.makePlan`. Reads once
    /// (not per-id), so a caller building an engine input isn't hitting `UserDefaults` in a
    /// per-recommendation loop.
    static func activeSuppressedIDs(now: Date = .now) -> Set<String> {
        Set(all.filter { now < $0.value.suppressUntil }.keys)
    }

    /// Exposed for the settings screen's "N dismissed suggestions" count — read-only.
    static var count: Int { all.count }
}
