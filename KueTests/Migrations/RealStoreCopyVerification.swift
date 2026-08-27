//
//  RealStoreCopyVerification.swift
//  KueTests
//
//  Manual verification tool used to diagnose and confirm the fix for the 2026-08-27 production
//  migration incident (NSCocoaErrorDomain 134504 opening a real pre-migration App Group
//  store — see `ModelContainerFactory.swift`'s "PRODUCTION INCIDENT" header and
//  `KueSchemaV1.swift`'s header for the full incident). Not part of the automated regression
//  suite (`RealV1SchemaRegressionTests` covers that with synthetic fixtures) and never
//  hardcodes a real device/simulator path or any real user content — it only reads a path a
//  developer supplies via a plain marker file, pointed at a byte-for-byte **copy** (never the
//  original) of a real store. With no such file present (the default — every normal `KueTests`
//  run, CI included), every test here is a no-op pass.
//
//  How this was actually used to verify the fix, without ever touching the real store:
//
//    STORE="$HOME/Library/Developer/CoreSimulator/Devices/<device>/data/Containers/Shared/AppGroup/<group>/Kue.sqlite"
//    COPY_DIR=$(mktemp -d)
//    cp -p "$STORE" "$COPY_DIR/Kue.sqlite"
//    cp -p "$STORE-wal" "$COPY_DIR/Kue.sqlite-wal" 2>/dev/null   # may not exist; fine either way
//    cp -p "$STORE-shm" "$COPY_DIR/Kue.sqlite-shm" 2>/dev/null
//    echo -n "$COPY_DIR/Kue.sqlite" > /tmp/kue_real_store_copy_path.txt
//    xcodebuild test -project Kue.xcodeproj -scheme Kue \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -only-testing:KueTests/RealStoreCopyVerification
//
//  `cp` (not `mv`, and reading the original only) plus a `mktemp -d` destination is exactly
//  "byte-for-byte copy... in a temporary test location" — the original file's mtime/inode are
//  never touched, and nothing here ever opens the original path itself. The path handoff is a
//  plain file rather than an environment variable because `xcodebuild test` doesn't reliably
//  propagate the invoking shell's environment into the Simulator's test-runner process.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@MainActor
struct RealStoreCopyVerification {
    /// Read from a plain file at a fixed, literal `/tmp` path (not `NSTemporaryDirectory()`,
    /// which resolves to a different, per-container sandboxed location depending on which
    /// process asks — the invoking host shell and the Simulator-hosted test process would see
    /// different directories) — and not an environment variable, since `xcodebuild test`
    /// doesn't reliably propagate the invoking shell's environment into the Simulator's
    /// test-runner process either. Absent by default, so every normal test run reads `nil`.
    private static var copyPath: String? {
        guard let contents = try? String(contentsOfFile: "/tmp/kue_real_store_copy_path.txt", encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @Test func aCopyOfTheRealStoreMigratesThroughTheCurrentChainWithoutLoss() throws {
        guard let path = Self.copyPath else { return } // no-op unless explicitly pointed at a copy

        let url = URL(fileURLWithPath: path)
        // The exact production path — `ModelContainerFactory.openThroughMigrationPlan(at:)` —
        // including its `recognizeAsV1IfPossible` recovery fallback, not a parallel
        // construction a test invented.
        let container = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        let context = container.mainContext

        let events = try context.fetch(FetchDescriptor<KueEvent>())
        #expect(!events.isEmpty, "expected at least the one known event in the real store copy")

        // Structural checks only — never assert on or print real title/notes/location content.
        for event in events {
            #expect(!event.id.uuidString.isEmpty)
            #expect(event.recurrence == nil) // every real pre-migration row is non-recurring
            #expect(event.seriesID == nil)
            #expect(event.externalCalendarEventIdentifier == nil) // pre-dates Calendar integration
            for task in event.tasks {
                #expect(task.event?.id == event.id)
            }
        }

        // Requirement: verify post-migration writes, closure, and reopening — on the copy only.
        let marker = UUID()
        context.insert(KueEvent(
            id: marker, title: "Migration Verification Marker", eventType: .generic,
            startDate: .now, estimatedDurationMinutes: 1, source: .manual
        ))
        try context.save()

        let reopened = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        let persisted = try #require(
            try reopened.mainContext.fetch(FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == marker })).first
        )
        #expect(persisted.title == "Migration Verification Marker")

        let originalCount = events.count
        let allEventsAfter = try reopened.mainContext.fetch(FetchDescriptor<KueEvent>())
        #expect(allEventsAfter.count == originalCount + 1)
    }
}
