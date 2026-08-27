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

    /// Shared with the widget extension (entity subtitle, widget copy) — lives here rather
    /// than an app-only Services file for that reason.
    var displayName: String {
        switch self {
        case .generic: return "Generic"
        case .deadline: return "Deadline"
        case .exam: return "Exam"
        case .interview: return "Interview"
        case .trip: return "Trip"
        }
    }
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
    /// Kue 2.0 Phase 4 — docs/18-calendar-integration.md. An explicit, user-confirmed
    /// import from Apple Calendar via `CalendarImportPipeline`; never set by anything
    /// running silently in the background.
    case calendarImport
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
    /// Kue 2.0 Phase 3 — real as of `KueSchemaV2`. Set identically on every occurrence sharing
    /// `seriesID`; nil for a non-recurring event. See docs/17-recurring-events.md.
    var recurrence: RecurrenceRule?
    /// Semantic payload marker, starts at 1 — see "Schema versioning". Distinct from SwiftData's
    /// own VersionedSchema/SchemaMigrationPlan, which govern the @Model shape itself.
    var schemaVersion: Int

    // MARK: - Kue 2.0 Phase 3 (KueSchemaV2) — recurrence occurrence identity, see
    // docs/17-recurring-events.md. Nil/false for every non-recurring event.

    /// Shared across every occurrence produced by one recurrence rule segment. Nil for a
    /// non-recurring event.
    var seriesID: UUID?
    /// This occurrence's slot per the rule, independent of `startDate` — the replenishment
    /// dedup key, and what a "This Occurrence" edit that moves `startDate` leaves untouched.
    var recurrenceAnchorDate: Date?
    /// True once this occurrence's fields were edited independently of the rule (a "This
    /// Occurrence" edit, or a skip) — reconciliation never regenerates or overwrites this row.
    var isRecurrenceException: Bool = false
    /// The third mutually-exclusive user-forceable state, alongside `isCancelled`/
    /// `isManuallyCompleted` — "this occurrence doesn't happen, the series continues."
    var isSkipped: Bool = false
    var skippedAt: Date?

    // MARK: - Kue 2.0 Phase 4 (KueSchemaV3) — Apple Calendar linkage, see
    // docs/18-calendar-integration.md. All nil for every event never exported/imported
    // through Calendar. Kue remains the source of truth: these fields only ever record
    // "what Calendar object this Kue event is explicitly linked to," never anything that
    // drives Kue's own scheduling/status/recurrence logic.

    /// `EKEvent.calendarItemExternalIdentifier` — stable across devices/re-syncs, unlike
    /// `eventIdentifier`. Set on successful export or import-from-an-existing-EKEvent;
    /// cleared by unlinking. Non-nil is exactly "this Kue event is linked to a Calendar event."
    var externalCalendarEventIdentifier: String?
    /// `EKCalendar.calendarIdentifier` of the calendar the linked event lives in (the
    /// destination calendar chosen at export, or the source calendar at import time).
    var externalCalendarIdentifier: String?
    /// Cached display name of `externalCalendarIdentifier`'s calendar, so the UI can show
    /// "Linked to Home" without re-fetching from EventKit just to render a label.
    var externalCalendarTitle: String?
    /// When Kue last successfully wrote to (exported or updated) the linked Calendar event.
    var externalCalendarLastSyncedAt: Date?
    /// `EKEvent.lastModifiedDate` as observed at that same successful write — the baseline
    /// `CalendarExportService.status(for:)` compares a freshly-fetched `EKEvent` against to
    /// detect an external change requiring an explicit conflict choice (never a silent
    /// overwrite).
    var externalCalendarLastKnownModifiedAt: Date?

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
        seriesID: UUID? = nil,
        recurrenceAnchorDate: Date? = nil,
        isRecurrenceException: Bool = false,
        isSkipped: Bool = false,
        skippedAt: Date? = nil,
        externalCalendarEventIdentifier: String? = nil,
        externalCalendarIdentifier: String? = nil,
        externalCalendarTitle: String? = nil,
        externalCalendarLastSyncedAt: Date? = nil,
        externalCalendarLastKnownModifiedAt: Date? = nil,
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
        self.seriesID = seriesID
        self.recurrenceAnchorDate = recurrenceAnchorDate
        self.isRecurrenceException = isRecurrenceException
        self.isSkipped = isSkipped
        self.skippedAt = skippedAt
        self.externalCalendarEventIdentifier = externalCalendarEventIdentifier
        self.externalCalendarIdentifier = externalCalendarIdentifier
        self.externalCalendarTitle = externalCalendarTitle
        self.externalCalendarLastSyncedAt = externalCalendarLastSyncedAt
        self.externalCalendarLastKnownModifiedAt = externalCalendarLastKnownModifiedAt
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
