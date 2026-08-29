//
//  NotificationActionHandler.swift
//  Kue
//
//  Kue 2.0 Phase 10.1 — docs/25-honest-event-outcomes-and-reminders.md "K." Registers the one
//  actionable category this phase adds (Mark Completed/Reschedule/Skip/Cancel, offered on the
//  outcome-follow-up notification — docs/25 "H.") and routes the user's choice back through
//  the exact same shared mutation services every other surface uses (`EventActions`), so a
//  notification action keeps SwiftData, pending notifications, both widget kinds, Spotlight,
//  and the focused Live Activity in sync exactly like a Home/Event Detail tap does — nothing
//  bespoke here. App-only: not part of `Kue/AppIntents`' `membershipExceptions` list, so this
//  file (and its `UIApplication` use) never compiles into the `KueShare` extension target,
//  which is exactly the constraint Phase 10's own `UIApplication.shared`-in-`KueShare` bug
//  taught (see docs/24 "Bugs found and fixed").
//

import Foundation
import UserNotifications
import SwiftData
import UIKit

enum NotificationActionHandler {
    /// Call once at launch, regardless of whether the store opened successfully — matches
    /// `BackgroundRefreshTask`'s own "register exactly once, before the app finishes
    /// launching" requirement for `UNUserNotificationCenter` delegate/category registration.
    static func registerCategories() {
        let complete = UNNotificationAction(
            identifier: NotificationActionIdentifiers.completeActionID,
            title: "Mark Completed",
            options: []
        )
        // `.foreground` — docs/25 "K.": Reschedule can't complete inside the notification
        // action itself, so it deep-links to the real Event Detail/edit flow instead of
        // pretending to reschedule.
        let reschedule = UNNotificationAction(
            identifier: NotificationActionIdentifiers.rescheduleActionID,
            title: "Reschedule",
            options: [.foreground]
        )
        let skip = UNNotificationAction(
            identifier: NotificationActionIdentifiers.skipActionID,
            title: "Skip",
            options: [.destructive]
        )
        let cancel = UNNotificationAction(
            identifier: NotificationActionIdentifiers.cancelActionID,
            title: "Cancel Event",
            options: [.destructive]
        )
        let outcomeCategory = UNNotificationCategory(
            identifier: NotificationActionIdentifiers.outcomeFollowUpCategory,
            actions: [complete, reschedule, skip, cancel],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([outcomeCategory])
    }

    /// A notification request's identifier is always `"<event UUID>-<transition suffix>"`
    /// (`NotificationCandidate.identifier`) — a UUID's string form is always exactly 36
    /// characters, so this is a safe, unambiguous parse even though some suffixes (and, in
    /// principle, task UUIDs within them) themselves contain hyphens.
    private static func eventID(fromRequestIdentifier identifier: String) -> UUID? {
        guard identifier.count > 36 else { return nil }
        return UUID(uuidString: String(identifier.prefix(36)))
    }

    /// Routes one notification action/tap. Mirrors `EventActions`' own defaulted-dependency
    /// shape so this stays swappable in tests the same way every other call site is.
    @MainActor
    static func handle(
        response: UNNotificationResponse,
        context: ModelContext,
        scheduler: NotificationScheduling = SystemNotificationScheduler.shared,
        liveActivityManager: LiveActivityManaging = SystemLiveActivityManager.shared,
        spotlightIndexer: SpotlightIndexing = SystemSpotlightIndexer.shared
    ) {
        guard let eventID = eventID(fromRequestIdentifier: response.notification.request.identifier) else { return }

        // Reschedule and a plain tap both just open the exact event through the app's one
        // real deep-link route (`RootTabView.onOpenURL`) — including when the event turns out
        // to be missing, which already renders the honest "unavailable" state there rather
        // than resolving to another event (docs/25 "K.").
        if response.actionIdentifier == NotificationActionIdentifiers.rescheduleActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            UIApplication.shared.open(KueDeepLink.url(for: .event(eventID)))
            return
        }

        // Complete/Skip/Cancel on an event that's since been deleted is a safe, silent no-op —
        // never resolves to another event.
        let descriptor = FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == eventID })
        guard let event = (try? context.fetch(descriptor))?.first else { return }

        switch response.actionIdentifier {
        case NotificationActionIdentifiers.completeActionID:
            EventActions.complete(event, context: context, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        case NotificationActionIdentifiers.skipActionID:
            EventActions.skip(event, context: context, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        case NotificationActionIdentifiers.cancelActionID:
            EventActions.cancel(event, context: context, scheduler: scheduler, liveActivityManager: liveActivityManager, spotlightIndexer: spotlightIndexer)
        default:
            break
        }
    }
}

/// Owns the `UNUserNotificationCenter.delegate` slot — a weak reference the system doesn't
/// retain for you, same reason every other long-lived system-facing manager in Kue
/// (`SystemLiveActivityManager.shared`, etc.) is a retained singleton. `context` is set once
/// in `KueApp.init()` after the store opens; `nil` (store failed to open) means every action
/// safely no-ops via `handle`'s own early guards never firing.
final class NotificationActionDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionDelegate()
    private override init() {}

    var context: ModelContext?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let context {
                NotificationActionHandler.handle(response: response, context: context)
            }
            completionHandler()
        }
    }

    /// Without this, a notification that fires while Kue is already in the foreground shows
    /// nothing at all (the system default when no delegate opts in) — exactly the kind of
    /// silent miss the incident motivating this phase already showed the cost of.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
