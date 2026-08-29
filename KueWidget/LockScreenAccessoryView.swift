//
//  LockScreenAccessoryView.swift
//  KueWidget
//
//  Post-Phase-12 fix — renders `LockScreenWidgetResolution` for `.accessoryCircular`/
//  `.accessoryRectangular`/`.accessoryInline`. Tap targets, per the feature's own spec: Event
//  Detail while the selected event still exists (`.tracking`/`.cancelled`/`.skipped` all carry
//  an `eventID`), the in-app Lock Screen selection page when it doesn't (`.noSelection`/
//  `.selectionUnavailable`) — never a long-press/Edit-Widget requirement, and never a silent
//  substitution for a different event. Same per-family view shapes
//  `AccessoryCircularTrackingView`/`AccessoryCircularStateView`/etc. (`WidgetAccessoryViews.swift`)
//  already establish, reused here rather than duplicated, same as `DedicatedCountdownEntryView`
//  already does for its own sibling policy.
//

import SwiftUI
import WidgetKit

struct LockScreenAccessoryView: View {
    let resolution: LockScreenWidgetResolution
    let family: WidgetFamily

    var body: some View {
        content
            .widgetURL(KueDeepLink.url(for: resolution.deepLinkDestination))
    }

    @ViewBuilder
    private var content: some View {
        switch resolution {
        case .tracking(let content):
            trackingBody(content)
        case .cancelled(_, let eventTitle):
            terminalBody(eventTitle: eventTitle, stateLabel: "Cancelled", symbol: "xmark.circle")
        case .skipped(_, let eventTitle):
            terminalBody(eventTitle: eventTitle, stateLabel: "Skipped", symbol: "arrow.uturn.forward.circle")
        case .noSelection:
            selectionBody(title: "Select Event", message: "Tap to choose an event.", symbol: "calendar.badge.plus")
        case .selectionUnavailable:
            selectionBody(title: "Select Another Event", message: "The chosen event is no longer available.", symbol: "questionmark.circle")
        }
    }

    @ViewBuilder
    private func trackingBody(_ content: WidgetDisplayContent) -> some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularTrackingView(content: content)
        case .accessoryRectangular:
            AccessoryRectangularTrackingView(content: content)
        default: // .accessoryInline
            Text("\(content.eventTitle) · \(WidgetAccessoryLabels.accessorySafeStatus(phase: content.phase, subline: content.subline))")
        }
    }

    @ViewBuilder
    private func terminalBody(eventTitle: String, stateLabel: String, symbol: String) -> some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularStateView(symbol: symbol, label: "\(eventTitle): \(stateLabel)")
        case .accessoryRectangular:
            AccessoryRectangularStateView(title: eventTitle, message: stateLabel)
        default: // .accessoryInline
            Text("\(Image(systemName: symbol)) \(eventTitle) · \(stateLabel)")
        }
    }

    @ViewBuilder
    private func selectionBody(title: String, message: String, symbol: String) -> some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularStateView(symbol: symbol, label: title)
        case .accessoryRectangular:
            AccessoryRectangularStateView(title: title, message: message)
        default: // .accessoryInline
            Text("\(Image(systemName: symbol)) \(title)")
        }
    }
}
