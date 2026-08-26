//
//  NotificationScheduling.swift
//  Kue
//
//  Dependency-injection seam around `UNUserNotificationCenter` (requirement 10) — every
//  notification-affecting call in this phase takes a `NotificationScheduling` with a live
//  default, mirroring how `EventActions`/`SchedulingEngine` already take a defaulted `now:
//  Date = .now` for testability. KueTests injects a fake and never touches the real
//  notification center (no permission prompt, no simulator-only nondeterminism).
//

import Foundation
import UserNotifications

protocol NotificationScheduling {
    /// Prompts the system permission dialog if not yet determined; a no-op returning the
    /// existing decision otherwise (the system never re-prompts).
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    /// Not read by `NotificationEngine` itself (which recomputes desired state from
    /// SwiftData rather than diffing against what's currently pending — see
    /// NotificationEngine.swift), but exposed for tests that want to assert on it directly.
    func pendingRequestIdentifiers() async -> [String]
}

/// `nonisolated` — otherwise `SystemNotificationScheduler.shared` can't be used as a default
/// parameter value under this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (default
/// argument expressions are isolation-checked independently of the isolation the function
/// they belong to eventually runs with). `UNUserNotificationCenter`'s own API is already
/// async/callable from any context, so there's no actual need for this to be MainActor-bound.
nonisolated final class SystemNotificationScheduler: NotificationScheduling {
    static let shared = SystemNotificationScheduler()
    private let center = UNUserNotificationCenter.current()
    private init() {}

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async {
        try? await center.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}
