//
//  KueWidget.swift
//  KueWidget
//
//  See docs/07-widget-engine.md and, for the family expansion below, docs/22-expanded-and-
//  dedicated-widgets.md "B." — Kue 2.0 Phase 8 added systemLarge and the three Lock Screen/
//  StandBy accessory families; small/medium behavior is unchanged.
//

import WidgetKit
import SwiftUI

struct KueWidget: Widget {
    let kind: String = WidgetKind.kue

    // Fully qualified: this file also compiles Shared/Models/WidgetConfiguration.swift's
    // `@Model` type of the same name, which would otherwise shadow SwiftUI's protocol
    // (the widget configuration protocol lives in SwiftUI, not WidgetKit, despite the name).
    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: KueWidgetConfigurationIntent.self,
            provider: KueEventProvider()
        ) { entry in
            KueWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Kue")
        .description("Track an upcoming event, or see what's next automatically.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}
