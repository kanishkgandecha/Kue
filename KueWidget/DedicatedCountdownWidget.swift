//
//  DedicatedCountdownWidget.swift
//  KueWidget
//
//  See docs/22-expanded-and-dedicated-widgets.md — a genuinely separate `Widget`/kind from
//  `KueWidget`, not a mode of it, so its own `AppIntentConfiguration` carries an independent
//  per-instance selection with no automatic-fallback code path at all.
//

import WidgetKit
import SwiftUI

struct DedicatedCountdownWidget: Widget {
    let kind: String = WidgetKind.dedicatedCountdown

    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DedicatedCountdownConfigurationIntentV3.self,
            provider: DedicatedCountdownProvider()
        ) { entry in
            DedicatedCountdownEntryView(entry: entry)
        }
        .configurationDisplayName("Dedicated Countdown")
        .description("Choose one event and keep it on your screen until you replace it.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}
