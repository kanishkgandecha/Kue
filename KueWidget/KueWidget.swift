//
//  KueWidget.swift
//  KueWidget
//
//  See docs/07-widget-engine.md — small/medium only per V1 ("Large is a stretch goal, not a
//  blocker for shipping V1" — docs/01-vision-and-scope.md). No Lock Screen families.
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
