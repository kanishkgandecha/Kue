//
//  PlanningActionRouter.swift
//  Kue
//
//  Kue 3.0 Phase 8 — docs/36 "F. Accept, edit, dismiss, and snooze". The one place a
//  recommendation's "Accept"/"Confirm Outcome"/"Add Focus Block to Calendar"/"Start Focus"
//  action turns into a real mutation — every branch below calls an *existing* mutation
//  service (`EventActions`, `TaskEditingService`, `LiveActivityFocusCoordinator`,
//  `CalendarProviding`) exactly the way Event Detail's own buttons already do, so accepting a
//  suggestion triggers the identical notification/Spotlight/widget/Live-Activity/sync
//  reconciliation any other mutation already gets — never a second, parallel mutation path
//  (requirement A/F). Dismiss/snooze never touch a model at all — they only ever write to
//  `RecommendationDismissalStore`.
//
//  A confirmed focus block is *never* written to SwiftData — there is no `FocusBlock` model
//  (docs/36 "I."), by design (see that doc's "Persistence" section). "Accept" on a focus-block
//  recommendation only records the dismissal so the same slot isn't re-proposed on the next
//  plan refresh; the two actions that produce a durable, user-visible artifact are
//  `addFocusBlockToCalendar` (a real `EKEvent`, via the existing `CalendarProviding.save`) and
//  `startFocus` (a real Live Activity, via the existing `LiveActivityFocusCoordinator`) —
//  exactly the two things requirement E lists as actually persisting/exporting.
//

import Foundation
import SwiftData

@MainActor
enum PlanningActionRouter {
    enum OutcomeChoice {
        case complete, skip, cancel
    }

    enum RoutingError: Error {
        case eventNotFound
        case taskNotFound
        case calendarUnavailable
    }

    // MARK: - Accept

    /// Applies whatever concrete mutation this recommendation's "Accept" represents. Only
    /// `.moveTaskEarlier` and a `.reduceTodaysLoad` that resolved a candidate date actually
    /// carry a `proposedDate` — every other category's primary action is navigation
    /// (Open Event/Open Task) or a separate explicit action (Confirm Outcome, Add Focus Block
    /// to Calendar, Start Focus), so this only fires for the date-change categories.
    static func accept(
        _ recommendation: PlanningRecommendation, context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared, now: Date = .now
    ) async throws {
        guard let proposedDate = recommendation.proposedDate,
              let taskID = recommendation.affectedTaskIDs.first,
              let task = try fetchTask(id: taskID, context: context) else {
            // A focus-block-only recommendation (Schedule Preparation / Protect a Focus
            // Block): nothing to mutate — just stop suggesting this exact slot again.
            RecommendationDismissalStore.dismiss(id: recommendation.id, now: now)
            return
        }
        await TaskEditingService.rescheduleTask(task, to: proposedDate, context: context, scheduler: scheduler, now: now)
        RecommendationDismissalStore.dismiss(id: recommendation.id, now: now)
    }

    // MARK: - Confirm Outcome (never automatic — always an explicit, user-picked choice)

    static func confirmOutcome(
        _ recommendation: PlanningRecommendation, as choice: OutcomeChoice, context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared,
        spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared, now: Date = .now
    ) async throws {
        guard let eventID = recommendation.affectedEventIDs.first, let event = try fetchEvent(id: eventID, context: context) else {
            throw RoutingError.eventNotFound
        }
        // Kue 3.0 Phase 8 correction pass — the awaitable variants: `confirmOutcome` is itself
        // `async`, so callers (the Today Plan views) already `await` it — there is no reason
        // to leave Live Activity/Spotlight reconciliation running in an orphaned `Task` past
        // that point, and tests need a real completion signal rather than a sleep.
        switch choice {
        case .complete:
            await EventActions.completeAwaitingReconciliation(event, context: context, now: now, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        case .skip:
            await EventActions.skipAwaitingReconciliation(event, context: context, now: now, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        case .cancel:
            await EventActions.cancelAwaitingReconciliation(event, context: context, now: now, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        }
        RecommendationDismissalStore.dismiss(id: recommendation.id, now: now)
    }

    // MARK: - Focus block actions

    /// Requirement E: "optionally add it to Apple Calendar using the existing Calendar
    /// abstraction." Mirrors `CalendarExportService`'s own fresh-`UUID` export pattern for a
    /// not-yet-linked item — a focus block has no prior Calendar linkage to update, so it's
    /// always a create, never an update.
    static func addFocusBlockToCalendar(_ block: FocusBlockProposal, calendarProvider: CalendarProviding, calendarIdentifier: String?) throws {
        guard calendarProvider.authorizationState().canWriteEvents else { throw RoutingError.calendarUnavailable }
        let event = KueCalendarEvent(
            externalIdentifier: UUID().uuidString, calendarIdentifier: calendarIdentifier ?? "",
            calendarTitle: "", title: block.title, startDate: block.start, endDate: block.end,
            isAllDay: false, location: nil, notes: "Focus block scheduled by Kue",
            timeZoneIdentifier: TimeZone.current.identifier, lastModifiedDate: nil, recurrence: nil
        )
        _ = try calendarProvider.save(event, in: calendarIdentifier)
    }

    // "Start Focus" (requirement E) is iOS-only — Live Activities/Dynamic Island don't exist
    // on macOS (see `Shared/Services/LiveActivity/SystemLiveActivityManager.swift`'s own
    // header), and `LiveActivityFocusCoordinator` lives under `Kue/Features/LiveActivity/`,
    // outside every target `Shared/` compiles into except the iOS app. That action is
    // implemented instead in `Kue/Services/Planning/PlanningFocusActions.swift`, an app-only
    // extension of this same router, rather than pulling an iOS-only type into shared code.

    // MARK: - Dismiss / snooze (never touch a model — docs/36 "F.")

    static func dismiss(_ recommendation: PlanningRecommendation, now: Date = .now) {
        RecommendationDismissalStore.dismiss(id: recommendation.id, now: now)
    }

    /// Default snooze target: the start of the next working day's planning window — the same
    /// "come back at a sensible time" default `bestAvailableSlot` itself searches from.
    static func snooze(_ recommendation: PlanningRecommendation, until: Date, now: Date = .now) {
        RecommendationDismissalStore.snooze(id: recommendation.id, until: until, now: now)
    }

    // MARK: - Lookup

    /// Not `private` — `Kue/Services/Planning/PlanningFocusActions.swift` (iOS-only, see
    /// above) resolves a focus block's `eventID` the same way for its Start Focus action.
    static func fetchEvent(id: UUID, context: ModelContext) throws -> KueEvent? {
        try context.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == id })).first
    }

    static func fetchTask(id: UUID, context: ModelContext) throws -> KueTask? {
        try context.fetch(FetchDescriptor<KueTask>(predicate: #Predicate { $0.id == id })).first
    }
}
