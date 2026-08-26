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
    static func handle(
        _ task: BackgroundTaskExecuting,
        context: ModelContext,
        scheduler: NotificationScheduling,
        backgroundScheduler: BackgroundTaskScheduling,
        now: Date = .now
    ) async {
        // Best-effort supplement, not the reliability guarantee itself (docs/08) — resubmit
        // the next opportunity up front so this run's failure/expiration doesn't end future
        // replenishment.
        backgroundScheduler.submit(identifier: BackgroundRefreshTask.identifier, earliestBeginDate: nil)

        var didExpire = false
        task.expirationHandler = { didExpire = true }

        EventReconciliation.run(context: context, now: now)
        guard !didExpire else {
            task.setTaskCompleted(success: false)
            return
        }

        // Passive trigger — never prompts for permission (docs/08 "Permission handling":
        // requested only "at the first point it's needed").
        let intensity = UserPreferenceStore.current(context: context).notificationIntensity
        await NotificationEngine.reschedule(context: context, intensity: intensity, scheduler: scheduler, now: now)

        task.setTaskCompleted(success: !didExpire)
    }
}
