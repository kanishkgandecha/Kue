//
//  SyncPerformanceBenchmarkTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 5 correction (requirement 7 — the disclosed gap the original Phase 5 report
//  never closed): a deterministic, 5,000-event sync benchmark, same "print the real measured
//  number, assert only a generous timing floor, and assert every correctness property
//  independent of timing" shape `MacPerformanceBenchmarkTests.swift`'s own header already
//  establishes for local persistence. Entirely `FakeSyncTransport`-backed — no real network —
//  the number measured here is `SyncCoordinator`'s own orchestration/mapping/reconciliation
//  cost, not Supabase's.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

extension KueMacAllTests {
    /// Exactly `defaultPageSize * maxPagesPerPass` — the largest dataset a *single* sync pass
    /// can fully reconcile without hitting the per-pass page cap (see `SyncCoordinatorTests
    /// .hittingThePerPassPageCapReportsChangesWaitingToDownloadNeverUpToDate` in KueTests/ for
    /// the dedicated correctness test of what happens one event past this boundary) — chosen
    /// deliberately, not coincidentally 5,000, so this benchmark's own `.upToDate` assertion
    /// below is a real correctness statement, not just a timing number.
    private static var benchmarkEventCount: Int { SyncCoordinator.defaultPageSize * SyncCoordinator.maxPagesPerPass }

    private func makeRemoteFixture(transport: FakeSyncTransport, now: Date) {
        for i in 0..<KueMacAllTests.benchmarkEventCount {
            let record = EventSyncRecord(
                id: UUID(), title: "Benchmark Event \(i)", eventType: "generic", startDate: now.addingTimeInterval(TimeInterval(i) * 3600),
                endDate: nil, estimatedDurationMinutes: 60, isAllDay: false, timeZoneIdentifier: "UTC",
                location: i % 3 == 0 ? "Room \(i % 20)" : nil, notes: nil, source: "manual", priority: "medium",
                isCancelled: false, cancelledAt: nil, isManuallyCompleted: false, manuallyCompletedAt: nil,
                recurrence: nil, seriesID: nil, recurrenceAnchorDate: nil, isRecurrenceException: false,
                isSkipped: false, skippedAt: nil,
                tasks: i % 4 == 0 ? [TaskSyncPayload(id: UUID(), title: "Prep", dueDate: now, isCompleted: false, completedAt: nil, offsetLabel: "1 hour before", sortOrder: 0)] : [],
                schedule: nil, widgetConfiguration: nil, createdAt: now, updatedAt: now, revision: 1
            )
            transport.seedRemoteEvent(record)
        }
    }

    @Test func fiveThousandEventSyncBenchmark() async {
        let clock = ContinuousClock()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = FakeSyncTransport()
        makeRemoteFixture(transport: transport, now: now)

        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let store = FakeSyncStateStore()
        var state = store.load()
        state.hasCompletedInitialSyncDecision = true
        store.save(state)
        let coordinator = SyncCoordinator(stateStore: store, transport: transport)
        let account = AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
        await account.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)

        SyncPreference.setEnabled(true)
        defer { SyncPreference.setEnabled(false) }

        let start = clock.now
        let status = await coordinator.sync(context: context, account: account)
        let syncDuration = clock.now - start
        print("[Benchmark] Full sync of \(KueMacAllTests.benchmarkEventCount) remote events: \(syncDuration)")

        // Correctness — independent of how long it took.
        #expect(status == .upToDate) // the whole dataset fit in one pass at exactly this size
        let localEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(localEvents.count == KueMacAllTests.benchmarkEventCount)
        #expect(localEvents.contains { $0.title == "Benchmark Event 0" })
        #expect(localEvents.contains { $0.title == "Benchmark Event \(KueMacAllTests.benchmarkEventCount - 1)" })
        let taskOwningEvents = localEvents.filter { !$0.tasks.isEmpty }
        #expect(taskOwningEvents.count == KueMacAllTests.benchmarkEventCount / 4)

        // A generous regression guard, not a tight performance target — the printed number
        // above is the real measurement.
        #expect(syncDuration < .seconds(60))
    }
}
