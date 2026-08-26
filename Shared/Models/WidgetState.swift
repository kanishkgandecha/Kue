//
//  WidgetState.swift
//  Kue
//
//  See docs/03-data-model.md "WidgetState" — precomputed, denormalized render state so
//  WidgetKit never has to compute "what phase are we in" at refresh time.
//

import Foundation
import SwiftData

/// docs/07-widget-engine.md "Widget lifecycle state machine" — a fixed, forward-only sequence.
enum WidgetLifecyclePhase: String, Codable, CaseIterable {
    case countdown, preparation, tomorrow, today, completed, removed
}

@Model
final class WidgetState {
    var id: UUID
    var event: KueEvent?
    var currentPhase: WidgetLifecyclePhase
    var headline: String
    var subline: String?
    /// 0.0–1.0, used by the `.progress` widget type only.
    var progress: Double?
    /// When WidgetKit should next ask for a reload.
    var nextTransitionDate: Date

    init(
        id: UUID = UUID(),
        event: KueEvent? = nil,
        currentPhase: WidgetLifecyclePhase,
        headline: String,
        subline: String? = nil,
        progress: Double? = nil,
        nextTransitionDate: Date
    ) {
        self.id = id
        self.event = event
        self.currentPhase = currentPhase
        self.headline = headline
        self.subline = subline
        self.progress = progress
        self.nextTransitionDate = nextTransitionDate
    }
}
