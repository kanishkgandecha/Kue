//
//  PlanningRecommendation.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36-smart-planning-and-productivity-intelligence.md. Immutable,
//  testable output values for `SmartPlanningEngine` — the engine never mutates a `KueEvent`/
//  `KueTask` itself (requirement: "produce a useful Today Plan... never silently mutate
//  events, tasks, reminders, recurrence rules, or outcomes"). Every type here is `nonisolated`
//  and `Equatable`, the same "plain, thread-safe value type" precedent `ScheduledTaskPlan`
//  (SchedulingEngine.swift) and `NotificationSchedulePlan` already establish, so the engine
//  that produces them can run off the main actor (requirement M) and be compared directly in
//  Swift Testing's `#expect`.
//

import Foundation

/// docs/36 "Recommendation categories" — section C's ten required categories, no more, no
/// fewer added speculatively (YAGNI: a hypothetical eleventh category with nothing driving it
/// would just be dead code).
nonisolated enum RecommendationCategory: String, Codable, CaseIterable, Equatable {
    case workOnNext
    case schedulePreparation
    case moveTaskEarlier
    case reduceTodaysLoad
    case resolveSchedulingConflict
    case reviewOverdueTask
    case confirmEventOutcome
    case prepareForUpcomingEvent
    case protectFocusBlock
    case reviewAtRiskEvent

    var displayName: String {
        switch self {
        case .workOnNext: return "Work on Next"
        case .schedulePreparation: return "Schedule Preparation"
        case .moveTaskEarlier: return "Move a Task Earlier"
        case .reduceTodaysLoad: return "Reduce Today's Load"
        case .resolveSchedulingConflict: return "Resolve Scheduling Conflict"
        case .reviewOverdueTask: return "Review Overdue Task"
        case .confirmEventOutcome: return "Confirm Event Outcome"
        case .prepareForUpcomingEvent: return "Prepare for Upcoming Event"
        case .protectFocusBlock: return "Protect a Focus Block"
        case .reviewAtRiskEvent: return "Review an At-Risk Event"
        }
    }

    var systemImage: String {
        switch self {
        case .workOnNext: return "arrow.right.circle"
        case .schedulePreparation: return "calendar.badge.plus"
        case .moveTaskEarlier: return "arrow.up.circle"
        case .reduceTodaysLoad: return "tray.and.arrow.up"
        case .resolveSchedulingConflict: return "exclamationmark.triangle"
        case .reviewOverdueTask: return "clock.badge.exclamationmark"
        case .confirmEventOutcome: return "questionmark.circle"
        case .prepareForUpcomingEvent: return "checklist"
        case .protectFocusBlock: return "shield"
        case .reviewAtRiskEvent: return "exclamationmark.circle"
        }
    }
}

/// docs/36 "Scoring" — a disclosed, three-level confidence rather than a fabricated
/// percentage (requirement J: "avoid false precision").
nonisolated enum RecommendationConfidence: String, Codable, CaseIterable, Comparable, Equatable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: RecommendationConfidence, rhs: RecommendationConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// docs/36 "Accept, edit, dismiss, and snooze" — requirement F's exact action list. Not every
/// recommendation offers every action; `PlanningRecommendation.availableActions` says which
/// apply to a given instance.
nonisolated enum PlanningSuggestedAction: String, Codable, CaseIterable, Equatable {
    case accept
    case editBeforeApplying
    case dismiss
    case snooze
    case openEvent
    case openTask
    case startFocus
    case addFocusBlockToCalendar
    case confirmOutcome
}

/// A proposed, not-yet-persisted focus block — requirement E: "not persisted or exported
/// until the user explicitly confirms it." This value is exactly that unconfirmed proposal;
/// nothing reads or writes it to SwiftData or Calendar on its own.
nonisolated struct FocusBlockProposal: Identifiable, Equatable {
    let id: String
    var start: Date
    var durationMinutes: Int
    var title: String
    var taskID: UUID?
    var eventID: UUID?

    var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
}

/// docs/36 "Every recommendation must contain..." — requirement B's exact field list.
nonisolated struct PlanningRecommendation: Identifiable, Equatable {
    /// Deterministic and content-derived (category + affected IDs + a coarse fingerprint of
    /// the fields that actually drove this recommendation) — never a fresh `UUID()`. This is
    /// what lets `RecommendationDismissalStore` tell "the same recommendation, still true"
    /// apart from "circumstances genuinely changed" without any extra bookkeeping: a changed
    /// due date, priority, or status naturally produces a different `id`, so an old dismissal
    /// keyed to the old `id` simply stops matching (docs/36 "Dismissal expiry").
    let id: String
    let category: RecommendationCategory
    let title: String
    let explanation: String
    let contributingFactors: [String]
    let confidence: RecommendationConfidence
    let suggestedAction: PlanningSuggestedAction
    let availableActions: [PlanningSuggestedAction]
    let affectedEventIDs: [UUID]
    let affectedTaskIDs: [UUID]
    let createdAt: Date
    let expiresAt: Date
    /// Non-nil only when this recommendation is being reported in a suppressed/unavailable
    /// state (e.g. Calendar access unavailable limited what could be checked) rather than
    /// omitted outright — requirement B's "reason it is suppressed or unavailable when
    /// relevant."
    let unavailableReason: String?
    let focusBlock: FocusBlockProposal?
    /// Set only for a recommendation whose "Accept" is a single concrete date change (e.g.
    /// "Move a Task Earlier") — `PlanningActionRouter.accept` reads this to know exactly what
    /// to apply without re-deriving it, and "Edit Before Applying" pre-fills a picker with it.
    let proposedDate: Date?

    init(
        id: String,
        category: RecommendationCategory,
        title: String,
        explanation: String,
        contributingFactors: [String],
        confidence: RecommendationConfidence,
        suggestedAction: PlanningSuggestedAction,
        availableActions: [PlanningSuggestedAction],
        affectedEventIDs: [UUID] = [],
        affectedTaskIDs: [UUID] = [],
        createdAt: Date,
        expiresAt: Date,
        unavailableReason: String? = nil,
        focusBlock: FocusBlockProposal? = nil,
        proposedDate: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.explanation = explanation
        self.contributingFactors = contributingFactors
        self.confidence = confidence
        self.suggestedAction = suggestedAction
        self.availableActions = availableActions
        self.affectedEventIDs = affectedEventIDs
        self.affectedTaskIDs = affectedTaskIDs
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.unavailableReason = unavailableReason
        self.focusBlock = focusBlock
        self.proposedDate = proposedDate
    }
}

/// docs/36 "Today Plan" — requirement D's exact content list, minus the date header (that's
/// just `date`, rendered by the view) and "honest empty state" (`emptyStateMessage`).
nonisolated struct TodayPlan: Equatable {
    let date: Date
    let mostImportantAction: PlanningRecommendation?
    let orderedRecommendations: [PlanningRecommendation]
    let focusBlocks: [FocusBlockProposal]
    let urgentItems: [PlanningRecommendation]
    let conflicts: [PlanningRecommendation]
    let preparationRisks: [PlanningRecommendation]
    let completedTodayCount: Int
    let totalTodayCount: Int
    /// requirement J: "Show 'limited information' when availability data is incomplete" —
    /// e.g. Calendar access wasn't available so busy-interval conflicts couldn't be checked.
    let limitedInformationNotice: String?
    let emptyStateMessage: String?

    static func empty(date: Date, emptyStateMessage: String) -> TodayPlan {
        TodayPlan(
            date: date, mostImportantAction: nil, orderedRecommendations: [], focusBlocks: [],
            urgentItems: [], conflicts: [], preparationRisks: [], completedTodayCount: 0,
            totalTodayCount: 0, limitedInformationNotice: nil, emptyStateMessage: emptyStateMessage
        )
    }
}
