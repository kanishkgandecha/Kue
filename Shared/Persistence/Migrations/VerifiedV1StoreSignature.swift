//
//  VerifiedV1StoreSignature.swift
//  Kue
//
//  Hardening (2026-08-28) of the 2026-08-27 production migration incident's fix (see
//  `KueSchemaV1.swift`'s header for the original incident, `ModelContainerFactory.swift`'s
//  header for the full recovery mechanism this signature gates). The original fix invoked its
//  legacy-recognition fallback after *any* staged-`ModelContainer` failure — reasonable in
//  spirit ("the fallback only mutates something a plain, no-plan open can already open
//  successfully"), but not rigorous: it never confirmed the failing store was *actually* a
//  genuine V1.0 store before attempting anything, which is not something an app should do to a
//  file it doesn't recognize.
//
//  This file is the one, documented, immutable definition of "what a genuine Kue V1.0 App
//  Group store's persistent-store metadata actually looks like." It was captured by reading
//  `Z_METADATA` from a byte-for-byte **copy** of the real store that caused the original
//  incident — never from the original device store itself, and never derived from
//  `KueSchemaV1`'s *current* Swift declaration, since that's exactly the thing under repair
//  here and must not be allowed to silently redefine what "verified" means. If `KueSchemaV1`
//  is ever edited again (it shouldn't be — see its own header), this signature does *not*
//  change with it; it is a historical fact, frozen the same way `KueSchemaV1` itself is.
//
//  `ModelContainerFactory`'s `recognizeAsV1IfPossible` fallback is only ever attempted when a
//  store's metadata — read via `NSPersistentStoreCoordinator.metadataForPersistentStore`,
//  *without* opening the store for migration (requirement 2) — matches this signature
//  *exactly*: store type, version identifiers, and this precise 7-entity hash set, no more, no
//  fewer, no approximation (requirement 3). A corrupted store, an unrelated app's store, a
//  V2/V3 store, a future/unknown version, or a store that merely happens to share some column
//  names all fail this match and are rejected outright (requirement 5) — the fallback is never
//  even attempted against them, let alone allowed to mutate them.
//

import Foundation
import CoreData

enum VerifiedV1StoreSignature {
    /// `NSStoreTypeKey`'s recorded value for every genuine V1.0 store — matches `NSSQLiteStoreType`.
    static let storeType = "SQLite"

    /// `NSStoreModelVersionIdentifiersKey`'s recorded value — SwiftData's own default
    /// `Schema.Version(1, 0, 0)`, exactly what `KueSchemaV1.versionIdentifier` also declares
    /// (see that file's header for why that's not a coincidence).
    static let versionIdentifiers: Set<String> = ["1.0.0"]

    /// `NSStoreModelVersionHashesKey`'s recorded value — the exact per-entity version hashes
    /// read from the real incident store's own metadata, base64-encoded here only because
    /// that's a convenient literal representation; the bytes themselves are the historical
    /// fact, not the encoding.
    static let entityVersionHashes: [String: Data] = [
        "KueEvent": Data(base64Encoded: "rtC7zI9uWAb8JCBS6KlNJMIn8NQVym/wNnSIXkk3GCE=")!,
        "KueSchedule": Data(base64Encoded: "dbUUyZ90dnVTHP/TRxAZz8+YwV136dz5sg7BIbD8xg4=")!,
        "KueTask": Data(base64Encoded: "ZCQVEcRc/TOyz2PfJfX3UVge81oyMORCIp7c9kxd3R8=")!,
        "Template": Data(base64Encoded: "SUOmAkg+8tk5oiKkfeEemLiiqYRyJoA6L3yDE70+1Go=")!,
        "UserPreference": Data(base64Encoded: "zrmcHFMnFFuwhcXytb0vmRcQNFiEN2tkW42j+HudBSA=")!,
        "WidgetConfiguration": Data(base64Encoded: "iIHtUEe31ZQqmQjxMFqef1en7inZC8PhyLkadBbDctQ=")!,
        "WidgetState": Data(base64Encoded: "QdXXYe3y4aaJ8iTLQULW/iDIYOI9f5zJ3JCoZ/J2Hlg=")!,
    ]

    /// Requirement 3/5 — exact match only. `metadata` is whatever
    /// `NSPersistentStoreCoordinator.metadataForPersistentStore(ofType:at:options:)` returns;
    /// every check below fails closed (returns `false`) on a missing/wrong-typed key rather
    /// than crashing or treating "couldn't tell" as "assume it matches."
    static func matches(metadata: [String: Any]) -> Bool {
        guard let type = metadata[NSStoreTypeKey] as? String, type == storeType else { return false }
        guard let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String],
              Set(identifiers) == versionIdentifiers else { return false }
        guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data] else { return false }
        // Exact 7-entity set — not "at least these," not "a subset of these." A partially
        // migrated store (some entities already at V2/V3 hashes) or an unrelated store that
        // happens to share a few entity names both fail this.
        guard Set(hashes.keys) == Set(entityVersionHashes.keys) else { return false }
        for (entityName, expectedHash) in entityVersionHashes {
            guard hashes[entityName] == expectedHash else { return false }
        }
        return true
    }
}
