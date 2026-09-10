//
//  MacPerformanceBenchmarkTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 1 cleanup — a deterministic, large-dataset performance benchmark, the gap
//  the original Phase 1 report disclosed rather than fabricating a number for. Fixture size
//  and every measured phase are fixed and printed to the test log (visible in `xcodebuild`
//  output) so the numbers in docs/29 are the literal output of this test, not an estimate.
//  Part of the single `@Suite(.serialized) KueMacAllTests` type (see
//  `MacModelContainerFactoryTests.swift`'s own header for why) — everything here uses a
//  throwaway on-disk temp store (`MacTestSupport`), never this Mac's real data.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

extension KueMacAllTests {
    /// Deterministic, not random — the same 5,000-event fixture every run, so a regression
    /// shows up as a real timing change, not fixture-to-fixture noise.
    private static let benchmarkEventCount = 5000

    private func makeBenchmarkFixture(context: ModelContext) {
        let types: [EventType] = [.generic, .deadline, .exam, .interview, .trip]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<Self.benchmarkEventCount {
            let event = KueEvent(
                title: "Benchmark Event \(i)",
                eventType: types[i % types.count],
                startDate: base.addingTimeInterval(TimeInterval(i) * 3600),
                estimatedDurationMinutes: 60,
                location: i % 3 == 0 ? "Room \(i % 20)" : nil,
                notes: i % 5 == 0 ? "Notes for event \(i)" : nil,
                source: .manual
            )
            context.insert(event)
            // A quarter of events carry a couple of prep tasks — a realistic mix, not an
            // artificially uniform one.
            if i % 4 == 0 {
                for t in 0..<2 {
                    let task = KueTask(
                        event: event,
                        title: "Task \(t) for event \(i)",
                        dueDate: event.startDate.addingTimeInterval(-3600),
                        offsetLabel: "1 hour before",
                        sortOrder: t
                    )
                    context.insert(task)
                }
            }
        }
    }

    @Test func largeDatasetPerformanceBenchmark() throws {
        let clock = ContinuousClock()
        let url = MacTestSupport.makeTemporaryStoreURL()
        defer { MacTestSupport.removeStore(at: url) }

        // 1. Bulk insert + save — simulates populating a store this size (e.g., a large
        // restored backup), not something Kue's own UI does in one operation, but the honest
        // upper bound for "how long can inserting this many rows possibly take."
        let container = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        let insertDuration = clock.measure {
            makeBenchmarkFixture(context: container.mainContext)
            try? container.mainContext.save()
        }
        print("[Benchmark] Insert + save \(Self.benchmarkEventCount) events: \(insertDuration)")

        // 2. Store opening at scale — an independent container at the same URL, mirroring
        // `aWrittenEventSurvivesAnIndependentCloseAndReopen`'s own "genuinely independent
        // reopen, not the same in-memory session" methodology. `reopened` is kept alive for
        // the rest of this test (not scoped to a `do` block) — a `ModelContext` doesn't hold
        // its own strong reference back to the `ModelContainer` that vended it (the same real
        // bug docs/29 "K." already documents finding and fixing elsewhere in this suite), so
        // letting `reopened` go out of scope while `allEvents` (backed by its context) is
        // still used below would risk the exact same crash.
        let start = clock.now
        let reopened = try ModelContainerFactory.openThroughMigrationPlan(at: url)
        let allEvents = try reopened.mainContext.fetch(FetchDescriptor<KueEvent>())
        let reopenDuration = clock.now - start
        print("[Benchmark] Reopen store + fetch all events: \(reopenDuration)")
        #expect(allEvents.count == Self.benchmarkEventCount)

        // 3. Home timeline grouping — the exact function `MacHomeListView`/iOS `HomeView` both
        // read on every appearance.
        let groupingDuration = clock.measure {
            _ = HomeTimelineGrouping.sections(events: allEvents)
            _ = HomeTimelineGrouping.needsAttentionEvents(events: allEvents)
        }
        print("[Benchmark] HomeTimelineGrouping over \(allEvents.count) events: \(groupingDuration)")

        // 4. Search — a representative query that matches a meaningful subset (every event
        // whose title contains "1" — ~1,900 of 5,000 events, not a worst-case near-empty or
        // near-total match).
        let searchDuration = clock.measure {
            _ = EventListQueryEngine.query(events: allEvents, searchText: "Benchmark Event 1", filter: .default, sort: .date)
        }
        print("[Benchmark] EventListQueryEngine search over \(allEvents.count) events: \(searchDuration)")

        // 5. Backup export — the one operation whose cost scales directly with the full
        // dataset every single time it's invoked (unlike the others, which only run against
        // whatever's currently visible).
        let exportDuration: Duration
        var exportedByteCount = 0
        var exportedData = Data()
        do {
            let start = clock.now
            let data = try BackupCoder.exportData(context: container.mainContext)
            exportedByteCount = data.count
            exportedData = data
            exportDuration = clock.now - start
        }
        print("[Benchmark] BackupCoder.exportData for \(Self.benchmarkEventCount) events: \(exportDuration) (\(exportedByteCount) bytes)")

        // 6. Cleanup round — Event Detail fetch by UUID, the exact lookup `RootSplitView`'s
        // own `selectedEvent` computed property performs (`allEvents.first { $0.id ==
        // selectedEventID }`) every time the sidebar selection changes. Benchmarked here as a
        // real `FetchDescriptor` predicate query (the store-level equivalent), not the in-memory
        // linear scan `RootSplitView` does over an already-fetched `@Query` array — the honest
        // worst case for what a UUID lookup against the store itself costs at this scale.
        let targetID = allEvents[allEvents.count / 2].id
        let fetchByIDDuration = clock.measure {
            var descriptor = FetchDescriptor<KueEvent>(predicate: #Predicate { $0.id == targetID })
            descriptor.fetchLimit = 1
            _ = try? reopened.mainContext.fetch(descriptor)
        }
        print("[Benchmark] Event Detail fetch by UUID from \(allEvents.count) events: \(fetchByIDDuration)")

        // 7. Cleanup round — backup restore-plan validation: `BackupCoder.decodeAndValidate`,
        // the checksum/version/JSON-decode step every `.kuebackup` import runs *before* ever
        // touching `ModelContext` (see that function's own header) — exercised here against
        // the full 5,000-event export from phase 5, not a small fixture file.
        let validateDuration = clock.measure {
            _ = try? BackupCoder.decodeAndValidate(exportedData)
        }
        print("[Benchmark] BackupCoder.decodeAndValidate for \(Self.benchmarkEventCount) events: \(validateDuration) (\(exportedByteCount) bytes)")

        // Generous upper bounds — this is a regression guard (something got dramatically
        // slower), not a tight performance target; the printed numbers above are the actual
        // reported measurement, not these bounds.
        #expect(insertDuration < .seconds(30))
        #expect(reopenDuration < .seconds(15))
        #expect(groupingDuration < .seconds(5))
        #expect(searchDuration < .seconds(5))
        #expect(exportDuration < .seconds(15))
        #expect(fetchByIDDuration < .seconds(5))
        #expect(validateDuration < .seconds(15))
    }
}
