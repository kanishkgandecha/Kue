//
//  KueShortcuts.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "C." — the App Shortcuts catalog
//  (Siri + the Shortcuts app's own suggested-actions list). iOS caps an app at 10 App
//  Shortcuts (a real, enforced limit — `appintentsmetadataprocessor` fails the build past it),
//  so this is a deliberately curated top 10, not all 15 intents in `Kue/AppIntents/`: every
//  intent still exists and is fully usable from a custom Shortcut or directly via Siri once
//  named, but only these 10 get an auto-suggested phrase/tile. Dropped from the curated list
//  (kept as plain intents): `CreateEventIntent` (folded into `QuickAddEventIntent`'s own
//  phrases — one "add" shortcut, not two near-duplicates), `CancelEventIntent`/
//  `SkipEventIntent`/`RestoreEventIntent` (less common than Complete), `SnoozeNextTaskIntent`
//  (paired with Complete Next Task in normal use, not usually invoked alone by voice).
//  `\(.applicationName)` (not a literal "Kue") so phrases still resolve correctly if the
//  app's display name is ever localized/renamed.
//

import AppIntents

struct KueShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .navy

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        if #available(iOS 26.0, *) {
            AppShortcut(
                intent: QuickAddEventIntent(),
                phrases: [
                    "Add an event in \(.applicationName)",
                    "Quick add to \(.applicationName)",
                ],
                shortTitle: "Quick Add",
                systemImageName: "sparkles"
            )
        }

        AppShortcut(
            intent: FindEventsIntent(),
            phrases: [
                "Find events in \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: "Find Events",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: OpenEventIntent(),
            phrases: ["Open an event in \(.applicationName)"],
            shortTitle: "Open Event",
            systemImageName: "arrow.up.forward.app"
        )

        AppShortcut(
            intent: CompleteEventIntent(),
            phrases: ["Complete an event in \(.applicationName)"],
            shortTitle: "Complete Event",
            systemImageName: "checkmark.circle"
        )

        AppShortcut(
            intent: CompleteNextTaskIntent(),
            phrases: [
                "Complete my next \(.applicationName) task",
                "Complete next task in \(.applicationName)",
            ],
            shortTitle: "Complete Next Task",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: ShowNextEventIntent(),
            phrases: [
                "What's next in \(.applicationName)?",
                "Show my next \(.applicationName) event",
            ],
            shortTitle: "Show Next Event",
            systemImageName: "arrow.right.circle"
        )

        AppShortcut(
            intent: ShowTodaysEventsIntent(),
            phrases: [
                "Show today's \(.applicationName) events",
                "What's on my \(.applicationName) today?",
            ],
            shortTitle: "Show Today",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: StartEventFocusIntent(),
            phrases: ["Start focus in \(.applicationName)"],
            shortTitle: "Start Focus",
            systemImageName: "bolt.fill"
        )

        AppShortcut(
            intent: StopEventFocusIntent(),
            phrases: [
                "Stop \(.applicationName) focus",
                "Stop focus in \(.applicationName)",
            ],
            shortTitle: "Stop Focus",
            systemImageName: "bolt.slash"
        )

        AppShortcut(
            intent: CreateEventFromTemplateIntent(),
            phrases: ["Create an event from a template in \(.applicationName)"],
            shortTitle: "Create from Template",
            systemImageName: "doc.badge.plus"
        )
    }
}
