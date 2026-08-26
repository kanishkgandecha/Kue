//
//  WidgetConfiguration.swift
//  Kue
//
//  See docs/03-data-model.md "WidgetConfiguration" — eligibility and default-rendering data
//  for an event's widget. Does NOT cause a widget to appear on the Home Screen (iOS only lets
//  the user place one) and deliberately has no size/family field — widget family is chosen
//  per placed instance by the user, not app-owned data. See docs/14-open-questions.md.
//

import Foundation
import SwiftData

/// Five selectable widget types. `.urgent` is NOT a case here — it's a cross-cutting visual
/// treatment applied on top of one of these, never a type itself (docs/07-widget-engine.md).
enum WidgetType: String, Codable, CaseIterable {
    case countdown, preparation, timeline, progress, checklist
}

@Model
final class WidgetConfiguration {
    var id: UUID
    var event: KueEvent?
    var widgetType: WidgetType
    var showLocation: Bool
    /// User can opt an event out of getting a widget at all.
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        event: KueEvent? = nil,
        widgetType: WidgetType,
        showLocation: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.event = event
        self.widgetType = widgetType
        self.showLocation = showLocation
        self.isEnabled = isEnabled
    }
}
