//
//  KueControls.swift
//  KueWidget
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "H." — the four Control Center/Lock
//  Screen controls. `ControlWidget`-conforming types are added directly into
//  `KueWidgetBundle`'s existing `body` (`WidgetBundleBuilder` auto-adapts a `ControlWidget`
//  into a `Widget` via `_ControlWidgetAdaptor` — confirmed against the WidgetKit/SwiftUI SDK
//  interfaces; no separate `ControlWidgetBundle`/`@main` is needed or exists as a distinct
//  mechanism). `StaticControlConfiguration` throughout: none of these controls need
//  per-instance user configuration.
//

import WidgetKit
import SwiftUI
import AppIntents

struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kanishkgandecha.Kue.QuickAddControl") {
            ControlWidgetButton(action: QuickAddControlIntent()) {
                Label("Quick Add", systemImage: "plus")
            }
        }
        .displayName("Quick Add Event")
        .description("Opens Kue to add a new event.")
    }
}

struct ShowNextEventControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kanishkgandecha.Kue.ShowNextEventControl") {
            ControlWidgetButton(action: ShowNextEventControlIntent()) {
                Label("Next Event", systemImage: "arrow.right.circle")
            }
        }
        .displayName("Show Next Event")
        .description("Opens Kue to your next upcoming event.")
    }
}

struct CompleteNextTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kanishkgandecha.Kue.CompleteNextTaskControl") {
            ControlWidgetButton(action: CompleteNextTaskControlIntent()) {
                Label("Complete Task", systemImage: "checkmark.circle")
            }
        }
        .displayName("Complete Next Task")
        .description("Marks your next event's soonest preparation task complete.")
    }
}

struct StopFocusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kanishkgandecha.Kue.StopFocusControl") {
            ControlWidgetButton(action: StopFocusControlIntent()) {
                Label("Stop Focus", systemImage: "bolt.slash")
            }
        }
        .displayName("Stop Kue Focus")
        .description("Ends whichever event's Live Activity is currently focused.")
    }
}
