//
//  RecurrenceExclusion.swift
//  Kue
//
//  Kue 2.0 Phase 3 — see docs/17-recurring-events.md "Deleting one occurrence." Deleting a
//  single materialized occurrence must permanently remove that slot, not just delete the row and
//  let the next replenishment recreate it (dedup is keyed on "does a row exist for this
//  anchor"). One row per user-initiated single-occurrence deletion — proportional to actual
//  deletions, not elapsed time, so this doesn't reintroduce unbounded growth. New in
//  `KueSchemaV2` — see Shared/Persistence/Migrations/KueSchemaV2.swift.
//

import Foundation
import SwiftData

@Model
final class RecurrenceExclusion {
    var id: UUID
    var seriesID: UUID
    var excludedAnchorDate: Date

    init(id: UUID = UUID(), seriesID: UUID, excludedAnchorDate: Date) {
        self.id = id
        self.seriesID = seriesID
        self.excludedAnchorDate = excludedAnchorDate
    }
}
