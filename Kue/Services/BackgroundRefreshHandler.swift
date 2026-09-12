//
//  BackgroundRefreshHandler.swift
//  Kue
//
//  See docs/08-notifications.md "Replenishment" and docs/04-event-types.md "Reconciliation"
//  point 2 — what actually runs when `BackgroundRefreshTask.identifier` fires: the same
//  status sweep as every other reconciliation point, plus a notification reschedule pass so
//  anything trimmed by the pending-request cap gets picked back up as budget frees.
//

import Foundation
import SwiftData

enum BackgroundRefreshHandler {
    /// Kue 3.0 Phase 5 — docs/33 "Background behavior": `syncCoordinator`/`accountCoordinator`
    /// are optional so every pre-existing call site (and every existing test) that only cares
    /// about the reconciliation/notification-reschedule half keeps compiling unchanged; `nil`
    /// (the default) simply skips the sync step, exactly as if this background pass predated
    /// Phase 5. The real `KueApp.init()` registration always passes both.
    static func handle(
        _ task: BackgroundTaskExecuting,
        context: ModelContext,
        scheduler: NotificationScheduling,
        backgroundScheduler: BackgroundTaskScheduling,
        syncCoordinator: SyncCoordinator? = nil,
        accountCoordinator: AccountCoordinator? = nil,
        // Kue 3.0 Phase 6 — docs/34 "Refresh behavior": same optional-parameter shape as
        // `syncCoordinator`/`accountCoordinator` above, for the exact same reason (every
        // pre-existing call site/test keeps compiling unchanged; `nil` skips this step).
        statisticsCoordinator: StatisticsCoordinator? = nil,
        now: Date = .now
    ) async {
        // Best-effort supplement, not the reliability guarantee itself (docs/08) — resubmit
        // the next opportunity up front so this run's failure/expiration doesn't end future
        // replenishment.
        backgroundScheduler.submit(identifier: BackgroundRefreshTask.identifier, earliestBeginDate: nil)

        var didExpire = false
        task.expirationHandler = { didExpire = true }

        await EventReconciliation.run(context: context, now: now)
        guard !didExpire else {
            task.setTaskCompleted(success: false)
            return
        }

        // Passive trigger — never prompts for permission (docs/08 "Permission handling":
        // requested only "at the first point it's needed").
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: scheduler, now: now)

        // Requirement Q: "reuse the existing background-refresh entry point where practical."
        // `SyncCoordinator.sync(context:account:)` itself already no-ops instantly if sync is
        // off, signed out, or backoff hasn't elapsed — no separate expiration check needed here
        // beyond the one `EventReconciliation`'s own step above already respects; a genuinely
        // slow network attempt inside `sync` is bounded by the transport's own 20-second
        // request timeout, comfortably inside a background task's real execution budget.
        if let syncCoordinator, let accountCoordinator, !didExpire {
            _ = await syncCoordinator.sync(context: context, account: accountCoordinator, now: now)
        }

        // Kue 3.0 Phase 6 — docs/34 "Refresh behavior": a sibling pass, independent of the
        // sync call above (requirement E — never chained through `SyncCoordinator`'s own
        // internals). No-ops instantly if the cloud-statistics preference is off.
        if let statisticsCoordinator, let accountCoordinator, !didExpire {
            let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
            _ = await statisticsCoordinator.refreshCloudUpload(events: events, account: accountCoordinator, now: now)
        }

        task.setTaskCompleted(success: !didExpire)
    }
}
