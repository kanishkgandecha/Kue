//
//  KueEvent.swift
//  Kue
//
//  See docs/03-data-model.md "KueEvent" — the canonical record of what's happening and when.
//

import Foundation
import SwiftData

/// V1 event type taxonomy — docs/03-data-model.md §"KueEvent", docs/04-event-types.md.
enum EventType: String, Codable, CaseIterable {
    case generic, deadline, exam, interview, trip
}

/// docs/03-data-model.md "EventStatus". `draft` is transient (pre-confirmation UI state only)
/// and must never be persisted. Every other case is either date-driven or set by
/// `isCancelled`/`isManuallyCompleted` — the event engine that derives `status` from those
/// (docs/04-event-types.md "Status transition rules") is Phase 2 work, not implemented here.
enum EventStatus: String, Codable, CaseIterable {
    case draft, upcoming, preparing, tomorrow, today, active, completed, cancelled, archived
}

/// docs/03-data-model.md "KueEvent" — which input path produced this event.
enum EventSource: String, Codable, CaseIterable {
    case manual, naturalLanguage, shareSheet
}

enum Priority: String, Codable, CaseIterable {
    case low, medium, high
}

@Model
final class KueEvent {
    var id: UUID
    var title: String
    var eventType: EventType
    var startDate: Date
    /// `.trip` only — required for `.trip`, nil for all other types. See "Completion timing".
    var endDate: Date?
    /// Point-in-time types only — see "Completion timing". Ignored when `endDate` is set.
    var estimatedDurationMinutes: Int
    /// True → `startDate`/`endDate` carry date-only semantics. See "All-day events".
    var isAllDay: Bool
    /// IANA identifier, captured from `TimeZone.current` at creation — see "Timezone policy".
    /// All offset/status math must use this, never the device's live timezone.
    var timeZoneIdentifier: String
    var location: String?
    var notes: String?
    var source: EventSource
    var priority: Priority
    /// Cached/derived — see docs/04-event-types.md "Status transition rules". Not written to
    /// directly by anything in Phase 1; defaults to `.upcoming` for a freshly created event.
    var status: EventStatus
    /// User-forceable input into status derivation; false by default.
    var isCancelled: Bool
    var cancelledAt: Date?
    /// User-forceable "mark complete" — see "Manual completion"; false by default.
    var isManuallyCompleted: Bool
    var manuallyCompletedAt: Date?
    /// Post-V1: always nil in V1, field reserved. See RecurrenceRule.swift.
    var recurrence: RecurrenceRule?
    /// Semantic payload marker, starts at 1 — see "Schema versioning". Distinct from SwiftData's
    /// own VersionedSchema/SchemaMigrationPlan, which govern the @Model shape itself.
    var schemaVersion: Int

    @Relationship(deleteRule: .cascade, inverse: \KueTask.event)
    var tasks: [KueTask]

    @Relationship(deleteRule: .cascade, inverse: \KueSchedule.event)
    var schedule: KueSchedule?

    @Relationship(deleteRule: .cascade, inverse: \WidgetConfiguration.event)
    var widgetConfiguration: WidgetConfiguration?

    @Relationship(deleteRule: .cascade, inverse: \WidgetState.event)
    var widgetState: WidgetState?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        eventType: EventType,
        startDate: Date,
        endDate: Date? = nil,
        estimatedDurationMinutes: Int,
        isAllDay: Bool = false,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        location: String? = nil,
        notes: String? = nil,
        source: EventSource,
        priority: Priority = .medium,
        status: EventStatus = .upcoming,
        isCancelled: Bool = false,
        cancelledAt: Date? = nil,
        isManuallyCompleted: Bool = false,
        manuallyCompletedAt: Date? = nil,
        recurrence: RecurrenceRule? = nil,
        schemaVersion: Int = 1,
        tasks: [KueTask] = [],
        schedule: KueSchedule? = nil,
        widgetConfiguration: WidgetConfiguration? = nil,
        widgetState: WidgetState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.eventType = eventType
        self.startDate = startDate
        self.endDate = endDate
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.source = source
        self.priority = priority
        self.status = status
        self.isCancelled = isCancelled
        self.cancelledAt = cancelledAt
        self.isManuallyCompleted = isManuallyCompleted
        self.manuallyCompletedAt = manuallyCompletedAt
        self.recurrence = recurrence
        self.schemaVersion = schemaVersion
        self.tasks = tasks
        self.schedule = schedule
        self.widgetConfiguration = widgetConfiguration
        self.widgetState = widgetState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// docs/03-data-model.md "Completion timing" — the exact boundary the widget/notification
    /// lifecycle (Phase 5+) needs between `today`, `active`, and `completed`. All-day events
    /// complete at end-of-day, not at the midnight instant `startDate` is normalized to.
    var effectiveEndDate: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        if isAllDay {
            let end = endDate ?? startDate
            return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end))!
        }
        return endDate ?? cal.date(byAdding: .minute, value: estimatedDurationMinutes, to: startDate)!
    }
}
