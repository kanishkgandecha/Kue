//
//  NotificationTestSupport.swift
//  KueTests
//
//  Shared fakes for Phase 8 (M7) — requirement 10: "protocols/test doubles around
//  UNUserNotificationCenter and background scheduling." No test file below ever constructs a
//  real `SystemNotificationScheduler`/`SystemBackgroundTaskScheduler` or touches
//  `UNUserNotificationCenter`/`BGTaskScheduler` directly. `FakeWidgetReloader` at the bottom
//  is the Phase 9 (M8) addition for the same reason — "timeline reload invocation through an
//  injectable wrapper" — reusing this file rather than starting a new one, same rationale.
//

import Foundation
import UserNotifications
@testable import Kue

@MainActor
final class FakeNotificationScheduler: NotificationScheduling {
    var authorizationStatusToReturn: UNAuthorizationStatus = .authorized
    var requestAuthorizationResult = true
    private(set) var requestAuthorizationCallCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifierBatches: [[String]] = []

    var addedIdentifiers: [String] { addedRequests.map(\.identifier) }
    var allRemovedIdentifiers: [String] { removedIdentifierBatches.flatMap { $0 } }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        if requestAuthorizationResult { authorizationStatusToReturn = .authorized }
        return requestAuthorizationResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusToReturn
    }

    func add(_ request: UNNotificationRequest) async {
        addedRequests.removeAll { $0.identifier == request.identifier } // dedup, same as a real center
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifierBatches.append(identifiers)
        addedRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingRequestIdentifiers() async -> [String] {
        addedRequests.map(\.identifier)
    }
}

@MainActor
final class FakeBackgroundTaskScheduler: BackgroundTaskScheduling {
    private(set) var registeredIdentifier: String?
    private(set) var registeredHandler: ((BackgroundTaskExecuting) -> Void)?
    private(set) var submittedIdentifiers: [String] = []

    @discardableResult
    func register(identifier: String, handler: @escaping (BackgroundTaskExecuting) -> Void) -> Bool {
        registeredIdentifier = identifier
        registeredHandler = handler
        return true
    }

    func submit(identifier: String, earliestBeginDate: Date?) {
        submittedIdentifiers.append(identifier)
    }
}

@MainActor
final class FakeBackgroundTask: BackgroundTaskExecuting {
    var expirationHandler: (() -> Void)?
    private(set) var completedSuccess: Bool?

    func setTaskCompleted(success: Bool) {
        completedSuccess = success
    }
}

@MainActor
final class FakeWidgetReloader: WidgetReloading {
    private(set) var reloadedKinds: [String] = []

    func reloadTimelines(ofKind kind: String) {
        reloadedKinds.append(kind)
    }
}
