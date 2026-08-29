//
//  LockScreenEventSelection.swift
//  Kue
//
//  Post-Phase-12 fix — Lock Screen widget event selection. Deliberately *not* a new
//  `UserPreference` (`@Model`) stored property or a new SwiftData model: that would require a
//  new `VersionedSchema`/migration stage for a single optional UUID, which this feature's own
//  spec says to avoid unless genuinely necessary (docs/15-schema-migrations.md). App Group
//  `UserDefaults` is the same sharing mechanism `LiveActivityPrivacyPreference`/
//  `ReminderPreference`/`SyncPreference` already use to reach the app and the widget extension
//  alike with no schema at all — same established pattern, same rationale.
//
//  This is a deliberately *global* selection: one UUID, shared by every placed Kue Lock Screen
//  accessory widget instance (`.accessoryCircular`/`.accessoryRectangular`/`.accessoryInline`
//  of the `KueWidget` kind specifically — not the Dedicated Countdown kind, which already has
//  its own genuinely independent per-instance `AppIntentConfiguration` selection and is
//  untouched by this feature). The in-app selection page explains this limitation honestly
//  rather than implying per-instance control it can't actually offer (WidgetKit gives an
//  `AppIntentConfiguration` a per-instance parameter, but this feature is deliberately *not*
//  built on that — see `KueWidgetConfigurationIntent`'s own doc comment for why: the Lock
//  Screen selection must work independently of Edit Widget).
//

import Foundation

enum LockScreenEventSelection {
    private static let selectedEventIDKey = "lockScreenWidget.selectedEventID"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerFactory.appGroupIdentifier) ?? .standard
    }

    /// `nil` means "no event selected" — the widget's own "Select Event" state, never a
    /// silent fallback to another event. Read fresh every call (cheap — `UserDefaults` already
    /// caches in memory) rather than cached, so a selection made in the app is visible to the
    /// widget extension's very next timeline request without any extra plumbing.
    static var current: UUID? {
        guard let string = defaults.string(forKey: selectedEventIDKey) else { return nil }
        // Fail closed: a corrupted/foreign value must never be treated as a selection that
        // happens to resolve to nothing — `nil` here reads as "no selection" everywhere else
        // in this feature reads `current`, same intent as a truly-never-set key.
        return UUID(uuidString: string)
    }

    /// Persists first, reloads second — "Persist the preference first" is this feature's own
    /// explicit ordering requirement, and the one call site that matters
    /// (`LockScreenEventSelectionView`) always wants both together, so bundling them here
    /// means there's no way to persist a change and forget the reload. `reloader` is
    /// injectable (default `SystemWidgetReloader.shared`, same DI seam every other
    /// widget-reloading call site in this codebase already uses) so this is directly testable
    /// with `FakeWidgetReloader`.
    static func select(_ eventID: UUID, reloader: WidgetReloading = SystemWidgetReloader.shared) {
        defaults.set(eventID.uuidString, forKey: selectedEventIDKey)
        reloader.reloadTimelines(ofKind: WidgetKind.kue)
    }

    static func clear(reloader: WidgetReloading = SystemWidgetReloader.shared) {
        defaults.removeObject(forKey: selectedEventIDKey)
        reloader.reloadTimelines(ofKind: WidgetKind.kue)
    }
}
