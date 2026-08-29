//
//  DedicatedCountdownConfigurationIntent.swift
//  KueWidget
//
//  See docs/22-expanded-and-dedicated-widgets.md "I." — the standard, Apple-provided
//  per-instance configuration mechanism (same shape as `KueWidgetConfigurationIntent`), the
//  system supplies the picker from the shared `KueEventOptionsProvider` automatically. Each placed
//  widget instance gets its own independent `event` value — this is what "not a global
//  app-wide preference" means structurally, not just by convention.
//

import WidgetKit
import AppIntents

/// V2 intentionally has a new App Intent identity. Early Phase 8 development builds shipped
/// this parameter with a different AppEntity type, and WidgetKit archives the intent schema
/// per placed instance. Reusing that identifier leaves those archives permanently unable to
/// deserialize the selection even after the parameter type is corrected.
struct DedicatedCountdownConfigurationIntentV3: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Dedicated Countdown"
    static var description = IntentDescription("Choose one event and keep it on your screen until you replace it.")

    @Parameter(title: "Event", optionsProvider: KueEventOptionsProvider())
    var eventID: String?
}
