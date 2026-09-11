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
//  reused verbatim as this plan's "default layer," unchanged, still gated by its own existing
//  terminal-event guard. Explicit `NotificationRule` rows are this plan's "rule layer," laid on
//  top: a rule with `anchor == .eventStart` suppresses *both* the default layer's `.eventStart`
//  and `.preEvent` candidates for that event (they're the same conceptual "event start family"
//  — see docs/31 "Rule model"), `.outcomeFollowUp` suppresses the default outcome follow-up,
//  and a task's `.taskDue` rule suppresses that task's default task-due candidate. This is what
//  "global-default changes must not silently rewrite existing events" and "preserve Kue 2.0/
//  3.0 Phase 1/2 behavior" both call for without duplicating or rewriting the already-tested
//  default-layer logic. The full typed-exclusion-reason pipeline (invalid/passed/terminal/
//  quiet-hours/capacity/...) applies in full to the rule layer, since that's the layer a user
//  actually sees and edits in Notification Studio; the default layer keeps its pre-existing
//  "silently produces nothing for a terminal event" contract, reused rather than re-derived —
//  see docs/31 "Planner" for the full reasoning around this boundary.
//

import Foundation

enum NotificationPlanner {
    struct Input {
        var events: [KueEvent]
        var globalPreferences: NotificationGlobalPreferences
        var intensity: NotificationIntensity
        var authorizationGranted: Bool
        var now: Date
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

    // MARK: - Per-event planning

    private static func planCandidates(
        for event: KueEvent,
        input: Input,
        globalReason: NotificationExclusionReason?
    ) -> (scheduled: [NotificationScheduledCandidate], excluded: [NotificationExcludedCandidate]) {
        var scheduled: [NotificationScheduledCandidate] = []
        var excluded: [NotificationExcludedCandidate] = []

        let eventLevelRules = event.notificationRules
        let eventHasOverride: (NotificationRuleAnchor) -> Bool = { anchor in eventLevelRules.contains { $0.anchor == anchor } }

        // MARK: Default layer (docs/08) — reused verbatim, unchanged.
        let defaultCandidates = NotificationCandidateBuilder.candidates(
            for: event, now: input.now,
            reminderPreference: ReminderPreference(preEventMinutes: input.globalPreferences.defaultPreEventMinutes)
        )
        let filteredDefaults = NotificationCandidateBuilder.filter(defaultCandidates, intensity: input.intensity)
        for candidate in filteredDefaults {
            // A custom event-level rule for the same anchor family supersedes the default —
            // never scheduled twice for the same conceptual reminder.
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

        // MARK: Rule layer — every explicit event- and task-level `NotificationRule`.
        var allRules = eventLevelRules
        for task in event.tasks { allRules += task.notificationRules }

        for rule in allRules.sorted(by: { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }) {
            let (ruleScheduled, ruleExcluded) = planRuleCandidate(rule, event: event, input: input, globalReason: globalReason)
            if let ruleScheduled { scheduled.append(ruleScheduled) }
            if let ruleExcluded { excluded.append(ruleExcluded) }
        }

        return (scheduled, excluded)
    }

    // MARK: - Rule-layer pipeline

    private static func planRuleCandidate(
        _ rule: NotificationRule,
        event: KueEvent,
        input: Input,
        globalReason: NotificationExclusionReason?
    ) -> (scheduled: NotificationScheduledCandidate?, excluded: NotificationExcludedCandidate?) {
        let identifier = "\(event.id)-rule-\(rule.id)"
        let task = rule.task

        func excluded(_ reason: NotificationExclusionReason, date: Date? = nil, explanation: String) -> (NotificationScheduledCandidate?, NotificationExcludedCandidate?) {
            (nil, NotificationExcludedCandidate(identifier: identifier, eventID: event.id, taskID: task?.id, sourceRuleID: rule.id, reason: reason, requestedDeliveryDate: date, explanation: explanation))
        }

        guard rule.isEnabled else {
            return excluded(.ruleDisabled, explanation: "This rule is disabled")
        }
        do {
            try NotificationRuleValidator.validate(rule)
        } catch {
            return excluded(.invalidRule, explanation: "This rule is invalid: \(error)")
        }
        if let globalReason {
            return excluded(globalReason, explanation: explanation(for: globalReason))
        }

        // Terminal / completed checks — the rule layer's own full pipeline (docs/31: never
        // silently drop; the default layer's own equivalent guard is reused as-is above).
        if event.status == .archived || event.isCancelled || event.isSkipped || event.isManuallyCompleted {
            return excluded(.eventTerminal, explanation: "This event is no longer active")
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

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneIdentifier) ?? .current
        let isEventStartFamily = rule.anchor == .eventStart && rule.offsetDirection == .at
        let quietHoursDecision = NotificationQuietHoursPolicy.decision(
            for: requestedDate, quietHours: input.globalPreferences.quietHours,
            isEventStart: isEventStartFamily,
            isTimeSensitive: rule.interruptionPreference == .timeSensitive && input.globalPreferences.timeSensitiveEnabled,
            calendar: calendar
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
            identifier: identifier, eventID: event.id, taskID: task?.id, sourceRuleID: rule.id,
            title: title, body: body,
            requestedDeliveryDate: requestedDate, effectiveDeliveryDate: effectiveDate,
            quietHoursAdjustment: adjustment, priority: priority(for: rule),
            sound: rule.sound, interruptionPreference: rule.interruptionPreference,
            explanation: ruleExplanation(for: rule),
            snoozeMinutes: rule.snoozeMinutes ?? input.globalPreferences.defaultSnoozeMinutes ?? 10
        )
        return (candidate, nil)
    }

    private static func requestedDeliveryDate(for rule: NotificationRule, event: KueEvent, task: KueTask?, input: Input) -> Date? {
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

    // MARK: - Priority (docs/31 "Capacity and prioritization")

    private static func priority(for rule: NotificationRule) -> Int {
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
        if lhs.eventID != rhs.eventID { return lhs.eventID.uuidString < rhs.eventID.uuidString }
        return (lhs.sourceRuleID?.uuidString ?? "") < (rhs.sourceRuleID?.uuidString ?? "")
    }

    // MARK: - Content / privacy

    private static func ruleContent(for rule: NotificationRule, event: KueEvent, task: KueTask?, privacy: NotificationPreviewPrivacy) -> (title: String, body: String) {
        let defaultTitle = event.title
        let defaultBody = rule.customBody ?? defaultRuleBody(for: rule, event: event, task: task)
        let title = rule.customTitle ?? defaultTitle
        return (title, applyPreviewPrivacy(title: title, body: defaultBody, event: event, task: task, privacy: privacy))
    }

    private static func defaultRuleBody(for rule: NotificationRule, event: KueEvent, task: KueTask?) -> String {
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

    private static func ruleExplanation(for rule: NotificationRule) -> String {
        switch rule.anchor {
        case .eventStart:
            if rule.offsetDirection == .at { return "At event start" }
            return "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") event start"
        case .eventEnd:
            if rule.offsetDirection == .at { return "At event end" }
            return "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") event end"
        case .outcomeFollowUp:
            return "Outcome follow-up"
        case .taskDue:
            if rule.offsetDirection == .at { return "At task due date" }
            return "\(rule.offsetQuantity) \(rule.offsetUnit.rawValue) \(rule.offsetDirection == .before ? "before" : "after") task due date"
        case .absolute:
            return "Custom date and time"
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
        case .eventTerminal: return "This event is no longer active"
        case .taskCompleted: return "This task is already completed"
        case .quietHoursSuppressed: return "Suppressed by quiet hours"
        case .systemCapacityLimit: return "Not scheduled — system capacity"
        case .duplicate: return "Superseded by another rule"
        case .missingEvent: return "The event could not be found"
        case .missingTask: return "The task could not be found"
        case .unsupportedPlatformBehavior: return "Not supported on this platform"
        }
    }
}
