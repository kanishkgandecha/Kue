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

    /// docs/07-widget-engine.md "Widget types (V1)" default-per-event-type mapping. Was
    /// private to `EventFormView.save()`; moved here (Kue 2.0 Phase 2) so
    /// `EventDuplicationService` — which needs the exact same default when a duplicated
    /// event's source somehow lacks a `WidgetConfiguration` — doesn't re-derive it.
    static func defaultType(for eventType: EventType) -> WidgetType {
        switch eventType {
        case .interview, .exam, .deadline: return .preparation
        case .trip: return .timeline
        case .generic: return .countdown
        }
    }
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
