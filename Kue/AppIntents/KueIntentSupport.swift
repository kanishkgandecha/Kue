//
//  KueIntentSupport.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "D./J." — the one shared "open the
//  store, resolve which event" + "open the app to an exact screen" helper every intent in this
//  folder calls, so none of them re-implement store-opening or deep-link self-navigation.
//

import Foundation
import SwiftData
import UIKit

enum KueIntentSupport {
    @MainActor
    static func makeContext() throws -> ModelContext {
        guard let container = ModelContainerFactory.makeDefaultOrNil() else { throw KueIntentError.storeUnavailable }
        return ModelContext(container)
    }

    /// The one event-lookup path every mutating/opening intent shares: prefer the explicit
    /// picker selection (`eventIDString`, from `KueAppEventOptionsProvider`) when it still
    /// resolves; otherwise fall back to a free-text title query (Siri's spoken "the interview"
    /// style invocation) — reusing `EventResolutionService` (Shared/), never a second lookup
    /// rule. Throws `.ambiguousEvent`/`.eventNotFound` rather than silently guessing.
    static func resolveEvent(eventIDString: String?, query: String?, context: ModelContext) throws -> KueEvent {
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []

        if let eventIDString, let id = UUID(uuidString: eventIDString),
           case .found(let event) = EventResolutionService.resolve(id: id, in: events) {
            return event
        }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else { throw KueIntentError.eventNotFound }

        switch EventResolutionService.resolve(title: trimmedQuery, in: events) {
        case .found(let event):
            return event
        case .ambiguous(let matches):
            throw KueIntentError.ambiguousEvent(titles: EventResolutionService.stableOrder(matches, limit: 5).map(\.title))
        case .notFound:
            throw KueIntentError.eventNotFound
        }
    }

    /// Self-opens Kue via its own registered `kue://` scheme — the exact same
    /// `RootTabView.onOpenURL` routing an external deep link already goes through, so no
    /// second in-process navigation mechanism is needed. Only meaningful for an intent whose
    /// `openAppWhenRun` is `true` (the app is already becoming foreground by the time
    /// `perform()` runs), matching every call site in this folder.
    @MainActor
    static func openDeepLink(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
