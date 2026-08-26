//
//  UserPreferenceStore.swift
//  Kue
//
//  See docs/03-data-model.md "UserPreference" — a singleton settings row with no seed step
//  anywhere yet (Phase 8 is the first consumer). Fetch-or-create so callers never have to
//  special-case "no row exists yet" themselves.
//

import Foundation
import SwiftData

enum UserPreferenceStore {
    @discardableResult
    static func current(context: ModelContext) -> UserPreference {
        if let existing = try? context.fetch(FetchDescriptor<UserPreference>()).first {
            return existing
        }
        let created = UserPreference()
        context.insert(created)
        try? context.save()
        return created
    }
}
