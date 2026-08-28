//
//  SpotlightReconciliation.swift
//  Kue
//
//  See docs/24-siri-shortcuts-spotlight-and-controls.md "G." — bounded, deterministic
//  Spotlight rebuild: every current `KueEvent` gets a fresh payload, everything else is
//  cleared first so a stale/renamed/deleted row can never linger. Used for initial indexing
//  (first launch), the Settings "Rebuild Index" control, and stale-index reconciliation.
//  Callers must run this off the main render pass (`Task { }`) — requirement: "Do not block
//  foreground UI on full reindexing." Per-mutation incremental updates (create/edit/status
//  change/delete) go through `EventActions`/`EventCreationService` directly instead of this
//  full-rebuild path — see those files.
//

import Foundation
import SwiftData

enum SpotlightReconciliation {
    @discardableResult
    static func reindexAll(context: ModelContext, indexer: SpotlightIndexing, now: Date = .now) async -> Int {
        guard SpotlightIndexingPreference.isEnabled else {
            await indexer.removeAll()
            return 0
        }
        let events = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let payloads = events.map { SpotlightEventPayloadBuilder.payload(for: $0, now: now) }
        await indexer.removeAll()
        await indexer.index(payloads)
        return payloads.count
    }
}
