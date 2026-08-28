//
//  SystemSpotlightIndexer.swift
//  Kue
//
//  The one file in `SpotlightIndexing`'s call graph that talks to real Core Spotlight — same
//  "one real-framework file, everything else pure/fake" shape `SystemLiveActivityManager`
//  (Phase 9) established. Private, on-device indexing only (`CSSearchableItem`, never
//  `CSPublicSettableSearchableItemAttributeSet`/public indexing) — no extra entitlement or
//  Info.plist key is required for this.
//
//  `CSSearchableIndex`'s Objective-C completion-handler methods aren't Swift-async-bridged in
//  this SDK (confirmed against the ObjC header — the completion-handler parameter carries no
//  `NS_SWIFT_ASYNC` annotation), so this wraps each call in `withCheckedContinuation` itself
//  rather than assuming an `async` overload exists.
//

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

nonisolated final class SystemSpotlightIndexer: SpotlightIndexing {
    static let shared = SystemSpotlightIndexer()
    private init() {}

    /// Groups every Kue-indexed item so `removeAll()` can clear them in one call
    /// (`deleteSearchableItems(withDomainIdentifiers:)`) without enumerating ids.
    static let domainIdentifier = "com.kanishkgandecha.Kue.events"

    static func uniqueIdentifier(for eventID: UUID) -> String {
        "kue-event-\(eventID.uuidString)"
    }

    func index(_ payloads: [SpotlightEventPayload]) async {
        guard SpotlightIndexingPreference.isEnabled, CSSearchableIndex.isIndexingAvailable(), !payloads.isEmpty else { return }
        let items = payloads.map(Self.makeItem)
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().indexSearchableItems(items) { _ in
                // Best-effort — a failed index write isn't user-facing (docs/13-error-
                // handling.md "degrade gracefully"); the next reconciliation pass retries.
                continuation.resume()
            }
        }
    }

    func remove(eventIDs: [UUID]) async {
        guard CSSearchableIndex.isIndexingAvailable(), !eventIDs.isEmpty else { return }
        let identifiers = eventIDs.map(Self.uniqueIdentifier(for:))
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { _ in
                continuation.resume()
            }
        }
    }

    func removeAll() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in
                continuation.resume()
            }
        }
    }

    private static func makeItem(_ payload: SpotlightEventPayload) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = payload.title
        attributes.displayName = payload.title
        // Privacy-safe secondary line only — event type + status, never notes/location.
        attributes.contentDescription = "\(payload.eventTypeDisplayName) · \(payload.statusLabel)"
        attributes.keywords = [payload.eventTypeDisplayName, payload.statusLabel]
        attributes.startDate = payload.effectiveDate
        attributes.allDay = NSNumber(value: payload.isAllDay)

        let item = CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier(for: payload.eventID),
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.isUpdate = true
        return item
    }
}
