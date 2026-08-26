//
//  KueTask.swift
//  Kue
//
//  See docs/03-data-model.md "KueTask" — a single preparation step belonging to an event.
//

import Foundation
import SwiftData

@Model
final class KueTask {
    var id: UUID
    var event: KueEvent?
    var title: String
    var dueDate: Date
    var isCompleted: Bool
    var completedAt: Date?
    /// Human-readable, e.g. "2 days before" — precomputed, not derived at render time.
    var offsetLabel: String
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        event: KueEvent? = nil,
        title: String,
        dueDate: Date,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        offsetLabel: String,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.event = event
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.offsetLabel = offsetLabel
        self.sortOrder = sortOrder
    }
}
