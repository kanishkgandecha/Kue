//
//  TemplateStore.swift
//  Kue
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Template notification defaults". `Template` rows
//  are created lazily, never eagerly (see `KueMigrationPlan.swift`'s own header) — a fresh
//  install or an upgraded store both start with zero `Template` rows, and the built-in row for
//  a given `EventType` is fetched-or-created the first time anything actually needs to read or
//  edit its notification defaults (the Templates editor UI, or `EventCreationService.create`'s
//  copy-at-creation step). This mirrors how `SchedulingEngine.defaultRules(for:)` already
//  supplies a hardcoded per-type default with no database row at all when nothing has been
//  customized — the only difference here is that a *customized* set of defaults needs somewhere
//  durable to live, and `Template` is that place.
//
//  One row per `EventType`, `isBuiltIn == true`. `isUserDefined` templates (docs/03-data-model.md
//  "Template" — Phase-3-scoped, not part of the live app today, per this pass's own
//  investigation) are out of scope: this store only ever fetches-or-creates the single built-in
//  row per type.
//

import Foundation
import SwiftData

enum TemplateStore {
    /// Fetches the one built-in `Template` for `eventType`, creating and inserting it (with no
    /// notification defaults and no schedule rules — matching `EventType`'s existing hardcoded
    /// defaults staying purely in-memory until something customizes them) if none exists yet.
    /// Never inserts a second row for the same type — callers can call this as many times as
    /// they like across a session.
    @discardableResult
    static func fetchOrCreateBuiltIn(for eventType: EventType, context: ModelContext) -> Template {
        if let existing = existingBuiltIn(for: eventType, context: context) {
            return existing
        }
        let template = Template(name: eventType.displayName, eventType: eventType, isUserDefined: false, isBuiltIn: true)
        context.insert(template)
        try? context.save()
        return template
    }

    /// Read-only lookup — never creates. Used by the copy-at-creation step, which should treat
    /// "no template row yet" identically to "a template row exists with zero defaults": both
    /// mean nothing to copy, not an error.
    ///
    /// Filters in plain Swift rather than a `#Predicate` comparing `$0.eventType` against a
    /// captured `EventType` value — that combination was found, via a real failing test, to
    /// silently match nothing (the fetch throws inside the predicate's SwiftData translation,
    /// and every call site here uses `try?`). There are at most a handful of `Template` rows
    /// ever (one per `EventType`), so an in-memory filter costs nothing.
    static func existingBuiltIn(for eventType: EventType, context: ModelContext) -> Template? {
        let all = (try? context.fetch(FetchDescriptor<Template>())) ?? []
        return all.first { $0.isBuiltIn && $0.eventType == eventType }
    }
}
