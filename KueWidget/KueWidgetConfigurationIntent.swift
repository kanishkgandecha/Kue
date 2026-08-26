//
//  KueWidgetConfigurationIntent.swift
//  KueWidget
//
//  See docs/07-widget-engine.md "Configured instance (primary)" — the standard,
//  Apple-provided per-instance configuration mechanism. No custom UI: the system supplies
//  the picker from `KueEventEntityQuery` automatically.
//

import WidgetKit
import AppIntents

struct KueWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Event"
    static var description = IntentDescription("Choose which event this widget tracks. Leave unset to show whatever's coming up next.")

    @Parameter(title: "Event")
    var event: KueEventEntity?
}
