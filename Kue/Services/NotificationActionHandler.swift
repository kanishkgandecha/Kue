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
        // Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze". `options: []` (no
        // `.foreground`) — a snooze is a same-identifier reschedule the action handler performs
        // entirely in the background, exactly like `SnoozeTaskIntent`'s own "routine and
        // reversible, no confirmation" precedent for the task-level snooze.
        let snooze = UNNotificationAction(
            identifier: NotificationActionIdentifiers.snoozeActionID,
            title: "Snooze",
            options: []
        )
        let ruleSnoozeCategory = UNNotificationCategory(
            identifier: NotificationActionIdentifiers.ruleSnoozeCategory,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([outcomeCategory, ruleSnoozeCategory])
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
    ) async {
        guard let eventID = eventID(fromRequestIdentifier: response.notification.request.identifier) else { return }

        // Kue 3.0 Phase 3 completion pass — docs/31 "Actions and snooze": a deterministic
        // same-identifier reschedule, nothing else. Never touches SwiftData/`KueEvent`/
        // `KueTask` — "reuse the existing notification action architecture" here means routing
        // through this same handler, not that a snooze needs (or should have) any event
        // mutation the way Complete/Skip/Cancel do.
        if response.actionIdentifier == NotificationActionIdentifiers.snoozeActionID {
            await snooze(response: response, scheduler: scheduler)
            return
        }

        // Reschedule and a plain tap both just open the exact event through the app's one
        // real deep-link route (`RootTabView.onOpenURL`) — including when the event turns out
        // to be missing, which already renders the honest "unavailable" state there rather
        // than resolving to another event (docs/25 "K.").
        if response.actionIdentifier == NotificationActionIdentifiers.rescheduleActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await UIApplication.shared.open(KueDeepLink.url(for: .event(eventID)))
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

    /// Re-adds the exact notification that just fired, same identifier and content, with a
    /// new one-shot trigger `minutesFromNow` later. `UNUserNotificationCenter.add(_:)` with an
    /// already-pending (or, here, just-delivered) identifier replaces it outright — this is
    /// the same "deterministic identifier, scoped reconciliation" guarantee
    /// `NotificationExecutor.reconcile` already relies on elsewhere, just invoked once, from
    /// here, instead of a full replan. The duration comes from `userInfo` set at schedule time
    /// (`NotificationExecutor.makeRequest`) — no SwiftData fetch, no `NotificationRule` lookup,
    /// nothing that could race a rule being edited/deleted in between.
    private static func snooze(response: UNNotificationResponse, scheduler: NotificationScheduling) async {
        guard let snoozedRequest = snoozedRequest(from: response.notification.request) else { return }
        await scheduler.add(snoozedRequest)
    }

    /// Pure — split out from `snooze(response:scheduler:)` above specifically so this is
    /// testable against a directly-constructed `UNNotificationRequest` (`UNNotificationResponse`
    /// itself has no public initializer, so it can't be built in a test at all). `nil` for a
    /// request with a missing or non-positive snooze duration — "disabled/missing snooze
    /// configuration" (this phase's own test requirement) means "do nothing," never a crash or
    /// a same-instant reschedule.
    static func snoozedRequest(from request: UNNotificationRequest) -> UNNotificationRequest? {
        guard let minutes = request.content.userInfo[NotificationActionIdentifiers.snoozeMinutesUserInfoKey] as? Int, minutes > 0 else { return nil }
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
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
                await NotificationActionHandler.handle(response: response, context: context)
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
