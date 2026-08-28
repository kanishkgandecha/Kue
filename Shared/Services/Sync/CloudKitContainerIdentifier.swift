//
//  CloudKitContainerIdentifier.swift
//  Kue
//
//  Kue 2.0 Phase 11 — docs/26 "T." The one CloudKit container identifier Kue uses, matching
//  the `iCloud.<bundle-id>` convention Apple's own capability tooling generates for
//  `com.kanishkgandecha.Kue`. A plain string constant (no CloudKit import needed to declare
//  it) so both the entitlements-adjacent documentation and `SystemCloudAccountProvider`/
//  `SystemCloudSyncTransport` (Kue/Services/Sync/, app-only) reference the exact same literal
//  — never a second, silently-different container.
//

import Foundation

nonisolated enum CloudKitContainerIdentifier {
    static let value = "iCloud.com.kanishkgandecha.Kue"
}
