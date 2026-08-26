//
//  KueSchemaV1.swift
//  Kue
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation. See docs/15-schema-migrations.md for the
//  full policy this file exists to satisfy.
//
//  `KueSchemaV1` is the *exact, currently-shipped* V1.0 model shape — every real App-Group
//  store already on a user's device was written against this shape — frozen here verbatim as
//  a `VersionedSchema` so it can be named as the starting point of a `SchemaMigrationPlan`.
//
//  This does **not** redefine `KueEvent`/`KueTask`/etc. — `VersionedSchema.models` just lists
//  the *existing* `@Model` types (Shared/Models/*.swift) as they stand today. There is nothing
//  to duplicate: with only one schema version so far, "the V1 shape" and "the current shape"
//  are the same types. Once Kue 2.0 introduces a real stored-property change, that change
//  lands in a **new** `KueSchemaV2` (new types, or the same types with the new shape — see
//  docs/15-schema-migrations.md "How to add a schema version"), and `KueSchemaV1` here must
//  never be edited again — it is a historical snapshot, not a moving target. Editing it after
//  the fact would silently change what "opening a v1.0 store" means for anyone who upgrades
//  later, defeating the entire point of versioning it.
//
//  `versionIdentifier = Schema.Version(1, 0, 0)` is not an arbitrary choice: it's SwiftData's
//  own default (`Schema.init(_:version:)`'s `version` parameter defaults to `Version(1, 0,
//  0)`), which is exactly what every real V1.0 store already has encoded in its metadata,
//  since `ModelContainerFactory.schema` was originally built via that same defaulted
//  initializer, before this migration foundation existed. Matching it here — rather than
//  picking a fresh `Version(1, 0, 0)`-looking-but-different identifier — is what lets
//  SwiftData recognize an existing store as already being this schema, not something needing
//  (or worse, unable to find) a migration path.
//

import SwiftData

enum KueSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            KueEvent.self,
            KueTask.self,
            KueSchedule.self,
            WidgetConfiguration.self,
            WidgetState.self,
            Template.self,
            UserPreference.self,
        ]
    }
}
