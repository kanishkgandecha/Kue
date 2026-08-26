//
//  BackgroundTaskScheduling.swift
//  Kue
//
//  See docs/08-notifications.md "Replenishment" and docs/04-event-types.md "Reconciliation"
//  point 2 — one `BGAppRefreshTask` identifier drives both notification-cap replenishment
//  and the status-reconciliation sweep, since both are "recompute derived state,
//  best-effort," not two independently-scheduled mechanisms.
//
//  `BackgroundTaskScheduling`/`BackgroundTaskExecuting` are the requirement-10 DI seam around
//  `BGTaskScheduler` — real `BGTask`s can't be constructed in a test host, and registering
//  the same identifier twice in one process crashes, so tests must never touch the real
//  scheduler at all.
//

import Foundation
import BackgroundTasks

enum BackgroundRefreshTask {
    /// Must match `Kue/Info.plist`'s `BGTaskSchedulerPermittedIdentifiers` entry exactly.
    static let identifier = "com.kanishkgandecha.Kue.refresh"
}

/// The minimal surface a fired background task exposes that the handler needs.
protocol BackgroundTaskExecuting: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

protocol BackgroundTaskScheduling {
    /// Registers the launch handler once, at app start. The system calls `handler` (on a
    /// background queue, not necessarily the main thread) when the task fires; tests call it
    /// directly instead.
    @discardableResult
    func register(identifier: String, handler: @escaping (BackgroundTaskExecuting) -> Void) -> Bool
    /// Requests a best-effort future execution — not guaranteed by iOS to run at any fixed
    /// cadence (docs/08-notifications.md).
    func submit(identifier: String, earliestBeginDate: Date?)
}

/// Owns the one real `BGTask` reference so `BackgroundTaskExecuting` never has to retroactively
/// conform the framework type itself.
private final class SystemBackgroundTask: BackgroundTaskExecuting {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
}

final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    static let shared = SystemBackgroundTaskScheduler()
    private init() {}

    @discardableResult
    func register(identifier: String, handler: @escaping (BackgroundTaskExecuting) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handler(SystemBackgroundTask(task))
        }
    }

    func submit(identifier: String, earliestBeginDate: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        // Best-effort (docs/08) — the simulator and a device with background refresh
        // disabled both throw here; there's nothing actionable to do with the error.
        try? BGTaskScheduler.shared.submit(request)
    }
}
