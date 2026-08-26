//
//  KueMigrationPlan.swift
//  Kue
//
//  Kue 2.0 Phase 1 — SwiftData Migration Foundation. See docs/15-schema-migrations.md.
//
//  The single source of truth for "every schema version Kue has ever shipped, in order, and
//  how to get from each to the next." Right now there is exactly one version (`KueSchemaV1`)
//  and zero stages — there is nothing to migrate *from* yet, since V1 is both the first and
//  current shape. This is the deliberately-empty foundation: the scaffolding future phases
//  extend, not a placeholder to delete later.
//
//  Adding `KueSchemaV2` (docs/15-schema-migrations.md has the full checklist): append it to
//  `schemas`, add a `.lightweight` or `.custom` `MigrationStage` from `KueSchemaV1.self` to
//  `KueSchemaV2.self` in `stages`, and add a migration test proving a real V1 store (with
//  representative data — reuse `MigrationTestSupport`/`MigrationFixtures` in KueTests/
//  Migrations/) survives the upgrade. Never edit `KueSchemaV1` itself to "fix" a V2 change —
//  see that file's own header for why.
//

import SwiftData

enum KueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KueSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
