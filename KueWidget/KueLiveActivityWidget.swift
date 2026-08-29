//
//  KueLiveActivityWidget.swift
//  KueWidget
//
//  See docs/23-live-activities-and-focus-mode.md "D./E." — the `ActivityConfiguration`
//  declaration itself; all actual layout lives in `LiveActivityViews.swift`. Deep-links reuse
//  `KueDeepLink` (Shared/), the same scheme the Dedicated Countdown widget already uses —
//  never a second URL parser.
//

import WidgetKit
import SwiftUI
import ActivityKit

struct KueLiveActivityWidget: Widget {
    // Fully qualified — see KueWidget.swift's own comment: this target also compiles
    // Shared/Models/WidgetConfiguration.swift's `@Model` type of the same bare name, which
    // would otherwise shadow SwiftUI's protocol here.
    var body: some SwiftUI.WidgetConfiguration {
        ActivityConfiguration(for: KueLiveActivityAttributes.self) { context in
            LiveActivityLockScreenView(attributes: context.attributes, state: context.state)
                .widgetURL(KueDeepLink.url(for: .event(context.attributes.eventID)))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityDynamicIslandExpandedLeading(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityDynamicIslandExpandedTrailing(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    LiveActivityDynamicIslandExpandedCenter(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityDynamicIslandExpandedBottom(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                LiveActivityCompactLeading(attributes: context.attributes, state: context.state)
            } compactTrailing: {
                LiveActivityCompactTrailing(state: context.state)
            } minimal: {
                LiveActivityMinimal(attributes: context.attributes, state: context.state)
            }
            .widgetURL(KueDeepLink.url(for: .event(context.attributes.eventID)))
        }
    }
}
