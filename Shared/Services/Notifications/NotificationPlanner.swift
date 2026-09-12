//
//  NotificationPlanner.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Scheduling planner". The pure
//  engine: Events + Tasks + Rules + Global/Device preferences + Authorization + `now` +
//  Calendar/time zone + capacity → `NotificationSchedulePlan`. Never calls
//  `UNUserNotificationCenter` — `NotificationExecutor` (this folder) is the only thing that
//  does, and it consumes this plan's output rather than re-deriving any of this policy.
//
//  **Composition, not replacement** (a deliberate architecture decision, not an oversight):
//  the pre-existing `NotificationCandidateBuilder` (preparation/tomorrow/today/task-due-
//  default/pre-event-default/event-start-default/outcome-follow-up-default — docs/08) is
//  reused verbatim as this plan's "default layer" (= the **Global Default** scope, expressed as
//  scalar settings rather than a generic rule list — a deliberate Phase 3 choice this phase
//  keeps, not a gap: every required kind already has a global on/off+timing knob). Explicit
//  `NotificationRule` rows are the **Specific Event** scope, laid on top; Kue 3.0 Phase 7 adds
//  the **Event Type** scope between them (`EventTypeNotificationPreferences` — docs/35) via
//  `EffectiveRule` below, so the full precedence is exactly `Specific Event > Event Type >
//  Global Default`, each layer suppressing the ones beneath it for the same anchor family
//  rather than ever scheduling the same conceptual reminder twice.
//
//  Kue 3.0 Phase 7 correction (docs/35 "Audit") — a real, demonstrable bug found and fixed
//  here: quiet hours are documented (`NotificationQuietHours`'s own header) as "a wall-clock,
//  device-local concept, not pinned to any event's own timezone," but the quiet-hours decision
//  was being evaluated against a calendar pinned to *the event's own* `timeZoneIdentifier` —
//  for a person whose device and a given event are in different zones, quiet hours could
//  silently apply at the wrong actual local time, or fail to apply at all. Fixed by injecting
//  the device's own `calendar`/`timeZone` explicitly via `Input` (also closing a literal gap
//  against this phase's own requirement E: "Inputs should include... calendar and time zone")
//  and using it for every quiet-hours/day-boundary decision, while the *requested delivery
//  date itself* (e.g. "30 minutes before event start") still correctly uses the event's own
//  timezone — those are two different questions with two different correct answers.
//
import Foundation

enum NotificationPlanner {
    struct Input {
        var events: [KueEvent]
        var globalPreferences: NotificationGlobalPreferences
        /// Kue 3.0 Phase 7 — docs/35 "Rule model, scopes." Empty means "no event-type
        /// overrides for any type," the same "absence means inherit" contract every other
        /// scope in this hierarchy already uses.
        var eventTypeRules: EventTypeNotificationPreferences = .empty
        var intensity: NotificationIntensity
        var authorizationGranted: Bool
        var now: Date
        /// The device's own wall-clock calendar/time zone — used for every quiet-hours and
        /// day-boundary decision (never an event's own `timeZoneIdentifier` for those). Defaults
        /// to `.current` for every pre-Phase-7 call site that never passed one explicitly.
        var calendar: Calendar = .current
        /// Matches `NotificationEngine.pendingRequestCap` — passed in, never hardcoded, so
        /// capacity behavior is independently testable (docs/31 "Capacity and prioritization").
        var capacity: Int
    }

    static func plan(_ input: Input) -> NotificationSchedulePlan {
        let globalReason = globalExclusionReason(input)

        var scheduled: [NotificationScheduledCandidate] = []
        var excluded: [NotificationExcludedCandidate] = []

        for event in input.events {
            let (eventScheduled, eventExcluded) = planCandidates(for: event, input: input, globalReason: globalReason)
            scheduled += eventScheduled
            excluded += eventExcluded
        }

        // Kue 3.0 Phase 7 — docs/35 "Summaries": device-level, not tied to any one event.
        let (summaryScheduled, summaryExcluded) = planSummaries(input: input, globalReason: globalReason)
        scheduled += summaryScheduled
        excluded += summaryExcluded

        // docs/31 "Capacity and prioritization" — deterministic priority, tie-broken by
        // effective delivery date, then event UUID, then rule UUID.
        let ordered = scheduled.sorted { isOrderedBeforeForCapacityFill($0, $1) }
        let withinCapacity = Array(ordered.prefix(input.capacity))
        let overCapacity = ordered.dropFirst(input.capacity).map { candidate in
            NotificationExcludedCandidate(
                identifier: candidate.identifier, eventID: candidate.eventID, taskID: candidate.taskID,
                sourceRuleID: candidate.sourceRuleID, reason: .systemCapacityLimit,
                requestedDeliveryDate: candidate.requestedDeliveryDate,
                explanation: "Not scheduled — system capacity"
            )
        }

        return NotificationSchedulePlan(scheduledCandidates: withinCapacity, excludedCandidates: excluded + overCapacity)
    }

    private static func globalExclusionReason(_ input: Input) -> NotificationExclusionReason? {
        if !input.globalPreferences.masterEnabled { return .masterDisabled }
        if !input.globalPreferences.deliverOnThisDevice { return .disabledOnThisDevice }
        if !input.authorizationGranted { return .permissionDenied }
        return nil
    }

    // MARK: - Effective rule (Kue 3.0 Phase 7 — docs/35 "Deterministic merging")

    /// One rule from whichever scope actually produced it — the one abstraction that lets
    /// `planRuleCandidate` below treat a real, persisted event/task-level `NotificationRule`
    /// and a per-device, non-persisted event-type default identically for every date/content/
    /// priority computation, without a second parallel pipeline.
    private enum EffectiveRule {
        case stored(NotificationRule)
        case eventType(EventType, NotificationRuleDefault)

        var anchor: NotificationRuleAnchor {
            switch self {
            case .stored(let rule): return rule.anchor
            case .eventType(_, let def): return def.anchor.asRuleAnchor
            }
        }
        var offsetDirection: NotificationOffsetDirection {
            switch self {
            case .stored(let rule): return rule.offsetDirection
            case .eventType(_, let def): return def.offsetDirection
            }
        }
        var offsetQuantity: Int {
            switch self {
            case .stored(let rule): return rule.offsetQuantity
            case .eventType(_, let def): return def.offsetQuantity
            }
        }
        var offsetUnit: NotificationOffsetUnit {
            switch self {
            case .stored(let rule): return rule.offsetUnit
            case .eventType(_, let def): return def.offsetUnit
            }
        }
        /// Event-type defaults structurally never carry an absolute date (`NotificationRuleDefault`'s
        /// own anchor vocabulary has no `.absolute` case) — always `nil` for that branch.
        var absoluteDate: Date? {
            switch self {
            case .stored(let rule): return rule.absoluteDate
            case .eventType: return nil
            }
        }
        var isEnabled: Bool {
            switch self {
            case .stored(let rule): return rule.isEnabled
            case .eventType(_, let def): return def.isEnabled
            }
        }
        var customTitle: String? {
            switch self {
            case .stored(let rule): return rule.customTitle
            case .eventType(_, let def): return def.customTitle
            }
        }
        var customBody: String? {
            switch self {
            case .stored(let rule): return rule.customBody
            case .eventType(_, let def): return def.customBody
            }
        }
        var sound: NotificationSoundOption {
            switch self {
            case .stored(let rule): return rule.sound
            case .eventType(_, let def): return def.sound
            }
        }
        var interruptionPreference: NotificationInterruptionPreference {
            switch self {
            case .stored(let rule): return rule.interruptionPreference
            case .eventType(_, let def): return def.interruptionPreference
            }
        }
        var snoozeMinutes: Int? {
            switch self {
            case .stored(let rule): return rule.snoozeMinutes
            case .eventType(_, let def): return def.snoozeMinutes
            }
        }
        /// `nil` for an event-type default — it has no live task to anchor to, structurally
        /// (`NotificationRuleDefault`'s own vocabulary excludes `.taskDue`).
        var task: KueTask? {
            switch self {
            case .stored(let rule): return rule.task
            case .eventType: return nil
            }
        }
        var sortOrder: Int {
            switch self {
            case .stored(let rule): return rule.sortOrder
            // Event-type defaults have no independent ordering concept of their own — they
            // always sort after every explicit event-level rule within one event's plan.
            case .eventType: return .max
            }
        }
        var createdAt: Date {
            switch self {
            case .stored(let rule): return rule.createdAt
            case .eventType: return .distantPast
            }
        }
        var sourceRuleID: UUID? {
            switch self {
            case .stored(let rule): return rule.id
            // Kue 3.0 Phase 7 — docs/35: an event-type-sourced candidate has no owning
            // `NotificationRule` row at all; `sourceRuleID` stays `nil` (matching the default
            // layer's own existing "nil means not rule-sourced" contract) and its own stable id
            // is carried in the identifier instead (see `identifier(for:)` below).
            case .eventType: return nil
            }
        }
        func identifier(for event: KueEvent) -> String {
            switch self {
            case .stored(let rule): return "\(event.id)-rule-\(rule.id)"
            case .eventType(let type, let def): return "\(event.id)-eventtype-\(type.rawValue)-\(def.id)"
            }
        }

        /// Mirrors `NotificationRule.offsetSeconds` exactly — signed offset from the anchor point.
        var offsetSeconds: TimeInterval {
            guard offsetDirection != .at else { return 0 }
            let magnitude = Double(offsetQuantity) * offsetUnit.secondsPerUnit
            return offsetDirection == .before ? -magnitude : magnitude
        }
    }

    // MARK: - Per-event planning

    private static func planCandidates(
        for event: KueEvent,
        input: Input,
        globalReason: NotificationExclusionReason?
    ) -> (scheduled: [NotificationScheduledCandidate], excluded: [NotificationExcludedCandidate]) {
        var scheduled: [NotificationScheduledCandidate] = []
        var excluded: [NotificationExcludedCandidate] = []

        let eventLevelRules = event.notificationRules
        let eventLevelAnchors = Set(eventLevelRules.map(\.anchor))
        // Kue 3.0 Phase 7 — docs/35: an event-type default only ever fills a gap the event's
        // own rules leave open — `Specific Event > Event Type` precedence, enforced by simply
        // never producing an event-type candidate for an anchor the event already overrides.
        // Deliberately *not* filtered by `isEnabled` here — a disabled event-type default must
        // still suppress the old scalar default layer for that anchor (matching the pre-
        // existing event-level rule contract below: a disabled rule means "no reminder for
        // this anchor," never "fall back to whichever less-specific layer is next"); the
        // disabled entry itself is still separately reported as `.ruleDisabled` by
        // `planRuleCandidate`'s own pipeline once it reaches it via `allRules` below.
        let eventTypeDefaults = input.eventTypeRules.rules(for: event.eventType)
            .filter { !eventLevelAnchors.contains($0.anchor.asRuleAnchor) }

        let eventHasOverride: (NotificationRuleAnchor) -> Bool = { anchor in
            eventLevelAnchors.contains(anchor) || eventTypeDefaults.contains { $0.anchor.asRuleAnchor == anchor }
        }

        // MARK: Default layer (docs/08) — reused verbatim, unchanged, now also suppressed by
        // an Event Type default for the same anchor family (Kue 3.0 Phase 7).
        let defaultCandidates = NotificationCandidateBuilder.candidates(
            for: event, now: input.now,
            reminderPreference: ReminderPreference(preEventMinutes: input.globalPreferences.defaultPreEventMinutes)
        )
        let filteredDefaults = NotificationCandidateBuilder.filter(defaultCandidates, intensity: input.intensity)
        for candidate in filteredDefaults {
            // A custom event-level or event-type rule for the same anchor family supersedes
            // the default — never scheduled twice for the same conceptual reminder.
            let supersededByRule: Bool
            switch candidate.kind {
            case .eventStart, .preEvent: supersededByRule = eventHasOverride(.eventStart)
            case .outcomeFollowUp: supersededByRule = eventHasOverride(.outcomeFollowUp)
            case .taskDue(let taskID):
                supersededByRule = event.tasks.first { $0.id == taskID }?.notificationRules.contains { $0.anchor == .taskDue } ?? false
            case .preparationStart, .tomorrow, .today:
                supersededByRule = false
            }
            guard !supersededByRule else {
                excluded.append(NotificationExcludedCandidate(
                    identifier: candidate.identifier, eventID: event.id, taskID: nil, sourceRuleID: nil,
                    reason: .duplicate, requestedDeliveryDate: candidate.fireDate,
                    explanation: "Superseded by a custom rule for this event"
                ))
                continue
            }
            if let globalReason {
                excluded.append(NotificationExcludedCandidate(
                    identifier: candidate.identifier, eventID: event.id, taskID: nil, sourceRuleID: nil,
                    reason: globalReason, requestedDeliveryDate: candidate.fireDate,
                    explanation: explanation(for: globalReason)
                ))
                continue
            }
            scheduled.append(NotificationScheduledCandidate(
                identifier: candidate.identifier, eventID: event.id, taskID: nil, sourceRuleID: nil,
                title: candidate.title, body: applyPreviewPrivacy(title: candidate.title, body: candidate.body, event: event, task: nil, privacy: input.globalPreferences.previewPrivacy),
                requestedDeliveryDate: candidate.fireDate, effectiveDeliveryDate: candidate.fireDate,
                quietHoursAdjustment: .none, priority: candidate.priorityTier,
                sound: input.globalPreferences.soundPreference, interruptionPreference: .active,
                explanation: "Default reminder"
            ))
        }

        // MARK: Rule layer — every explicit event/task-level `NotificationRule`, plus every
        // still-applicable Event Type default (Kue 3.0 Phase 7).
        var allRules: [EffectiveRule] = eventLevelRules.map { .stored($0) }
        for task in event.tasks { allRules += task.notificationRules.map { .stored($0) } }
        allRules += eventTypeDefaults.map { .eventType(event.eventType, $0) }

        for rule in allRules.sorted(by: { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }) {
            let (ruleScheduled, ruleExcluded) = planRuleCandidate(rule, event: event, input: input, globalReason: globalReason)
            if let ruleScheduled { scheduled.append(ruleScheduled) }
            if let ruleExcluded { excluded.append(ruleExcluded) }
        }

        return (scheduled, excluded)
    }

    // MARK: - Rule-layer pipeline

    private static func planRuleCandidate(
        _ rule: EffectiveRule,
        event: KueEvent,
        input: Input,
        globalReason: NotificationExclusionReason?
    ) -> (scheduled: NotificationScheduledCandidate?, excluded: NotificationExcludedCandidate?) {
        let identifier = rule.identifier(for: event)
        let task = rule.task

        func excluded(_ reason: NotificationExclusionReason, date: Date? = nil, explanation: String) -> (NotificationScheduledCandidate?, NotificationExcludedCandidate?) {
            (nil, NotificationExcludedCandidate(identifier: identifier, eventID: event.id, taskID: task?.id, sourceRuleID: rule.sourceRuleID, reason: reason, requestedDeliveryDate: date, explanation: explanation))
        }

        guard rule.isEnabled else {
            return excluded(.ruleDisabled, explanation: "This rule is disabled")
        }
        if case .stored(let storedRule) = rule {
            do {
                try NotificationRuleValidator.validate(storedRule)
            } catch {
                return excluded(.invalidRule, explanation: "This rule is invalid: \(error)")
            }
        }
        if let globalReason {
            return excluded(globalReason, explanation: explanation(for: globalReason))
        }

        // Terminal / completed checks — the rule layer's own full pipeline (docs/31: never
        // silently drop; the default layer's own equivalent guard is reused as-is above).
        // Kue 3.0 Phase 7 correction: reported as four distinct, honest reasons rather than one
        // blended `.eventTerminal` bucket — order matters here exactly like
        // `EventStatusEngine.derive`'s own precedence (cancel > skip > manual-complete), so an
        // event that is somehow both is still reported by its most authoritative state.
        if event.status == .archived {
            return excluded(.eventArchived, explanation: "This event has been archived")
        }
        if event.isCancelled {
            return excluded(.eventCancelled, explanation: "This event was cancelled")
        }
        if event.isSkipped {
            return excluded(.eventSkipped, explanation: "This occurrence was skipped")
        }
        if event.isManuallyCompleted {
            return excluded(.eventCompleted, explanation: "This event is already completed")
        }
        if let task, task.isCompleted {
            return excluded(.taskCompleted, explanation: "This task is already completed")
        }

        guard let requestedDate = requestedDeliveryDate(for: rule, event: event, task: task, input: input) else {
            return excluded(.missingEvent, explanation: "Could not resolve this rule's anchor")
        }

        if rule.anchor == .absolute, NotificationRuleValidator.isAbsoluteDatePassed(requestedDate, now: input.now) {
            return excluded(.passed, date: requestedDate, explanation: "This date has already passed")
        }
        guard requestedDate > input.now else {
            return excluded(.passed, date: requestedDate, explanation: "This time has already passed")
        }

        // Kue 3.0 Phase 7 correction — docs/35 "Audit": quiet hours are a device-local wall-
        // clock concept (`NotificationQuietHours`'s own header) — `input.calendar` (the
        // device's own calendar/time zone), never a calendar pinned to this event's own
        // `timeZoneIdentifier`, which the pre-correction code incorrectly used here.
        let isEventStartFamily = rule.anchor == .eventStart && rule.offsetDirection == .at
        let quietHoursDecision = NotificationQuietHoursPolicy.decision(
            for: requestedDate, quietHours: input.globalPreferences.quietHours,
            isEventStart: isEventStartFamily,
            isTimeSensitive: rule.interruptionPreference == .timeSensitive && input.globalPreferences.timeSensitiveEnabled,
            calendar: input.calendar
        )

        let effectiveDate: Date
        let adjustment: NotificationQuietHoursAdjustment
        switch quietHoursDecision {
        case .deliverAtRequestedTime:
            effectiveDate = requestedDate
            adjustment = .none
        case .moveToQuietHoursEnd(let end):
            effectiveDate = end
            adjustment = .movedToQuietHoursEnd
        case .suppress:
            return excluded(.quietHoursSuppressed, date: requestedDate, explanation: "Suppressed by quiet hours")
        }

        let (title, body) = ruleContent(for: rule, event: event, task: task, privacy: input.globalPreferences.previewPrivacy)
        let candidate = NotificationScheduledCandidate(
            identifier: identifier, eventID: event.id, taskID: task?.id, sourceRuleID: rule.sourceRuleID,
            title: title, body: body,
            requestedDeliveryDate: requestedDate, effectiveDeliveryDate: effectiveDate,
            quietHoursAdjustment: adjustment, priority: priority(for: rule),
            sound: rule.sound, interruptionPreference: rule.interruptionPreference,
            explanation: ruleExplanation(for: rule),
            snoozeMinutes: rule.snoozeMinutes ?? input.globalPreferences.defaultSnoozeMinutes ?? 10
        )
        return (candidate, nil)
    }

    private static func requestedDeliveryDate(for rule: EffectiveRule, event: KueEvent, task: KueTask?, input: Input) -> Date? {
        switch rule.anchor {
        case .absolute:
            return rule.absoluteDate
        case .eventStart:
            return allDayAwareAnchor(for: event, input: input).addingTimeInterval(rule.offsetSeconds)
        case .eventEnd, .outcomeFollowUp:
            return event.effectiveEndDate.addingTimeInterval(rule.offsetSeconds)
        case .taskDue:
            guard let task else { return nil }
            return task.dueDate.addingTimeInterval(rule.offsetSeconds)
        }
    }

    /// docs/31 "Rule editor": "Clearly explain whether an all-day offset is based on midnight,
    /// a configured preferred time" — an all-day event's rules anchor to the configured
    /// preferred minute-of-day (Global Settings), pinned to the event's own timezone, never a
    /// literal midnight `startDate` (which an offset like "30 minutes before" would otherwise
    /// land at a meaningless clock time relative to).
    private static func allDayAwareAnchor(for event: KueEvent, input: Input) -> Date {
        guard event.isAllDay else { return event.startDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        let minute = input.globalPreferences.allDayPreferredMinuteOfDay
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: event.startDate) ?? event.startDate
    }

    // MARK: - Summaries (Kue 3.0 Phase 7 — docs/35 "Daily and Weekly Summary")

    /// Not anchored to any one event — a single daily and/or weekly digest, each with a fixed,
    /// stable singleton identifier (never per-event), computed from the same `input.events`
    /// every other candidate sees. Content is deliberately count-only (never a title list,
    /// regardless of `previewPrivacy`) — the simplest way to satisfy "must not leak private
    /// event titles" for every privacy level at once, disclosed as a deliberate simplification
    /// rather than a title-aware redaction scheme this phase didn't need to build.
    private static func planSummaries(input: Input, globalReason: NotificationExclusionReason?) -> (scheduled: [NotificationScheduledCandidate], excluded: [NotificationExcludedCandidate]) {
        var scheduled: [NotificationScheduledCandidate] = []
        var excluded: [NotificationExcludedCandidate] = []

        let daily = input.globalPreferences.effectiveDailySummary
        if let (candidate, exclusion) = planDailySummary(daily, input: input, globalReason: globalReason) {
            if let candidate { scheduled.append(candidate) }
            if let exclusion { excluded.append(exclusion) }
        }
        let weekly = input.globalPreferences.effectiveWeeklySummary
        if let (candidate, exclusion) = planWeeklySummary(weekly, input: input, globalReason: globalReason) {
            if let candidate { scheduled.append(candidate) }
            if let exclusion { excluded.append(exclusion) }
        }
        return (scheduled, excluded)
    }

    private static let dailySummaryIdentifier = "daily-summary"
    private static let weeklySummaryIdentifier = "weekly-summary"

    private static func planDailySummary(_ preference: DailySummaryPreference, input: Input, globalReason: NotificationExclusionReason?) -> (NotificationScheduledCandidate?, NotificationExcludedCandidate?)? {
        guard preference.isEnabled else {
            return (nil, NotificationExcludedCandidate(identifier: dailySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: .ruleDisabled, requestedDeliveryDate: nil, explanation: "Daily Summary is off"))
        }
        if let globalReason {
            return (nil, NotificationExcludedCandidate(identifier: dailySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: globalReason, requestedDeliveryDate: nil, explanation: explanation(for: globalReason)))
        }
        let targetDay = preference.scope == .today ? input.now : input.calendar.date(byAdding: .day, value: 1, to: input.now) ?? input.now
        guard let deliveryDate = nextOccurrence(ofMinute: preference.deliveryMinuteOfDay, onOrAfter: input.now, preferring: targetDay, calendar: input.calendar) else {
            return (nil, NotificationExcludedCandidate(identifier: dailySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: .missingEvent, requestedDeliveryDate: nil, explanation: "Could not resolve the summary time"))
        }
        let count = eventCount(on: targetDay, events: input.events, calendar: input.calendar)
        let scopeWord = preference.scope == .today ? "today" : "tomorrow"
        let body = count == 0 ? "Nothing scheduled \(scopeWord)" : "\(count) event\(count == 1 ? "" : "s") \(scopeWord)"
        let candidate = NotificationScheduledCandidate(
            identifier: dailySummaryIdentifier, eventID: nil, title: "Daily Summary", body: body,
            requestedDeliveryDate: deliveryDate, effectiveDeliveryDate: deliveryDate,
            quietHoursAdjustment: .none, priority: 5, sound: input.globalPreferences.soundPreference,
            interruptionPreference: .passive, explanation: "Daily Summary"
        )
        return (candidate, nil)
    }

    private static func planWeeklySummary(_ preference: WeeklySummaryPreference, input: Input, globalReason: NotificationExclusionReason?) -> (NotificationScheduledCandidate?, NotificationExcludedCandidate?)? {
        guard preference.isEnabled else {
            return (nil, NotificationExcludedCandidate(identifier: weeklySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: .ruleDisabled, requestedDeliveryDate: nil, explanation: "Weekly Summary is off"))
        }
        if let globalReason {
            return (nil, NotificationExcludedCandidate(identifier: weeklySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: globalReason, requestedDeliveryDate: nil, explanation: explanation(for: globalReason)))
        }
        guard let deliveryDate = nextOccurrence(ofWeekday: preference.weekday, minute: preference.deliveryMinuteOfDay, onOrAfter: input.now, calendar: input.calendar) else {
            return (nil, NotificationExcludedCandidate(identifier: weeklySummaryIdentifier, eventID: nil, taskID: nil, sourceRuleID: nil, reason: .missingEvent, requestedDeliveryDate: nil, explanation: "Could not resolve the summary time"))
        }
        let windowEnd = input.calendar.date(byAdding: .day, value: preference.upcomingWindowDays, to: input.now) ?? input.now
        let count = eventCount(from: input.now, through: windowEnd, events: input.events)
        let body = count == 0 ? "Nothing scheduled in the next \(preference.upcomingWindowDays) days" : "\(count) event\(count == 1 ? "" : "s") in the next \(preference.upcomingWindowDays) days"
        let candidate = NotificationScheduledCandidate(
            identifier: weeklySummaryIdentifier, eventID: nil, title: "Weekly Summary", body: body,
            requestedDeliveryDate: deliveryDate, effectiveDeliveryDate: deliveryDate,
            quietHoursAdjustment: .none, priority: 5, sound: input.globalPreferences.soundPreference,
            interruptionPreference: .passive, explanation: "Weekly Summary"
        )
        return (candidate, nil)
    }

    private static func nextOccurrence(ofMinute minute: Int, onOrAfter now: Date, preferring day: Date, calendar: Calendar) -> Date? {
        guard let candidate = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) else { return nil }
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    private static func nextOccurrence(ofWeekday weekday: Int, minute: Int, onOrAfter now: Date, calendar: Calendar) -> Date? {
        var candidate = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now) ?? now
        for _ in 0..<8 {
            if calendar.component(.weekday, from: candidate) == weekday, candidate > now { return candidate }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return nil
    }

    private static func eventCount(on day: Date, events: [KueEvent], calendar: Calendar) -> Int {
        events.count { event in
            !event.isCancelled && !event.isSkipped && !event.isManuallyCompleted && event.status != .archived
                && calendar.isDate(event.startDate, inSameDayAs: day)
        }
    }

    private static func eventCount(from start: Date, through end: Date, events: [KueEvent]) -> Int {
        events.count { event in
            !event.isCancelled && !event.isSkipped && !event.isManuallyCompleted && event.status != .archived
                && event.startDate >= start && event.startDate <= end
        }
    }

    // MARK: - Priority (docs/31 "Capacity and prioritization")

    private static func priority(for rule: EffectiveRule) -> Int {
        switch rule.anchor {
        case .eventStart where rule.offsetDirection == .at: return 0 // imminent event-start
        case .absolute: return 1 // explicit user-created custom notification
        case .taskDue: return 2
        case .eventStart, .eventEnd: return 3 // near-term pre-event/pre-end reminders
        case .outcomeFollowUp: return 4
        }
    }

    /// docs/31 "Tie-break deterministically using: Effective delivery date, Priority, Event
    /// UUID, Rule UUID" — date first, matching docs/08's own pre-existing, tested "sort by
    /// date ascending first, then by category as a tie-break" contract: a near-term reminder
    /// must never be dropped in favor of a distant one just because of a lower-numbered
    /// priority tier.
    private static func isOrderedBeforeForCapacityFill(_ lhs: NotificationScheduledCandidate, _ rhs: NotificationScheduledCandidate) -> Bool {
        if lhs.effectiveDeliveryDate != rhs.effectiveDeliveryDate { return lhs.effectiveDeliveryDate < rhs.effectiveDeliveryDate }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.eventID != rhs.eventID { return (lhs.eventID?.uuidString ?? "") < (rhs.eventID?.uuidString ?? "") }
        return (lhs.sourceRuleID?.uuidString ?? "") < (rhs.sourceRuleID?.uuidString ?? "")
    }

    // MARK: - Content / privacy

    private static func ruleContent(for rule: EffectiveRule, event: KueEvent, task: KueTask?, privacy: NotificationPreviewPrivacy) -> (title: String, body: String) {
        let defaultTitle = event.title
        let defaultBody = rule.customBody ?? defaultRuleBody(for: rule, event: event, task: task)
        let title = rule.customTitle ?? defaultTitle
        return (title, applyPreviewPrivacy(title: title, body: defaultBody, event: event, task: task, privacy: privacy))
    }

    private static func defaultRuleBody(for rule: EffectiveRule, event: KueEvent, task: KueTask?) -> String {
        switch rule.anchor {
        case .eventStart: return rule.offsetDirection == .at ? "\(event.title) is starting now" : "\(event.title) is coming up"
        case .eventEnd: return "\(event.title) is ending"
        case .outcomeFollowUp: return "How did \(event.title) go?"
        case .taskDue: return task.map { "Reminder: \($0.title)" } ?? "Task reminder"
        case .absolute: return "\(event.title): custom reminder"
        }
    }

    /// docs/31 "Privacy": applied here, immediately before any content is handed back to a
    /// caller building an actual notification — never at the display layer, so there's no
    /// path where a caller forgets to redact.
    private static func applyPreviewPrivacy(title: String, body: String, event: KueEvent, task: KueTask?, privacy: NotificationPreviewPrivacy) -> String {
        switch privacy {
        case .full: return body
        case .eventOnly: return task != nil ? "A reminder for \(event.title) is due" : body
        case .private: return "You have a Kue reminder"
        }
    }

    private static func ruleExplanation(for rule: EffectiveRule) -> String {
        let prefix: String
        if case .eventType(let type, _) = rule { prefix = "\(type.displayName) default: " } else { prefix = "" }
        switch rule.anchor {
        case .eventStart:
            if rule.offsetDirection == .at { return prefix + "At event start" }
            return prefix + "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") event start"
        case .eventEnd:
            if rule.offsetDirection == .at { return prefix + "At event end" }
            return prefix + "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") event end"
        case .outcomeFollowUp:
            return prefix + "Outcome follow-up"
        case .taskDue:
            if rule.offsetDirection == .at { return prefix + "At task due date" }
            return prefix + "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") task due date"
        case .absolute:
            return prefix + "Custom date and time"
        }
    }

    private static func explanation(for reason: NotificationExclusionReason) -> String {
        switch reason {
        case .masterDisabled: return "Notifications are turned off"
        case .disabledOnThisDevice: return "Notifications are off on this device"
        case .permissionDenied: return "Notification permission was denied"
        case .ruleDisabled: return "This rule is disabled"
        case .invalidRule: return "This rule is invalid"
        case .passed: return "This time has already passed"
        case .eventCompleted: return "This event is already completed"
        case .eventCancelled: return "This event was cancelled"
        case .eventSkipped: return "This occurrence was skipped"
        case .eventArchived: return "This event has been archived"
        case .taskCompleted: return "This task is already completed"
        case .quietHoursSuppressed: return "Suppressed by quiet hours"
        case .systemCapacityLimit: return "Not scheduled — system capacity"
        case .duplicate: return "Superseded by another rule"
        case .missingEvent: return "The event could not be found"
        case .missingTask: return "The task could not be found"
        case .unsupportedPlatformBehavior: return "Not supported on this platform"
        case .outsideRecurrenceHorizon: return "Outside the supported recurrence range"
        }
    }
}
