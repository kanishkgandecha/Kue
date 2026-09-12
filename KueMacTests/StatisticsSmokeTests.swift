//
//  StatisticsSmokeTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 6 — docs/34 "Testing." A spot check that `Shared/Services/Statistics/` and
//  the extended `ProfileStatisticsEngine` run correctly reached from the `KueMac` module, not a
//  second copy of `KueTests/Statistics/`'s own exhaustive coverage of the same pure types. One
//  representative case per area, matching `AccountSharedServiceSmokeTests.swift`'s own
//  precedent — `FakeStatisticsTransport`/`FakeCloudStatisticsStateStore`/`FakeAccountProvider`
//  only, never real networking.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

// Part of the single `KueMacAllTests` suite — see `MacModelContainerFactoryTests.swift`'s
// header for why all `KueMacTests` files share one `@Suite(.serialized)` type.
extension KueMacAllTests {
    @Test func profileStatisticsEngineComputesOnTheMacModule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = KueEvent(title: "Mac Exam", eventType: .exam, startDate: now.addingTimeInterval(-3600), estimatedDurationMinutes: 60, source: .manual, isManuallyCompleted: true, createdAt: now, updatedAt: now)
        let statistics = ProfileStatisticsEngine.compute(events: [event], now: now)
        #expect(statistics.completedEvents == 1)
        #expect(statistics.completedCountsByEventType[.exam] == 1)
    }

    @Test func statisticsCoordinatorUploadsWhenEnabledAndSignedInOnKueMac() async {
        CloudStatisticsPreference.setEnabled(true)
        defer { CloudStatisticsPreference.setEnabled(false) }
        let transport = FakeStatisticsTransport()
        let coordinator = StatisticsCoordinator(stateStore: FakeCloudStatisticsStateStore(), transport: transport)
        let account = AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore())
        await account.signIn(email: FakeAccountProvider.fixtureEmail, password: FakeAccountProvider.fixturePassword)
        let status = await coordinator.refreshCloudUpload(events: [], account: account)
        guard case .upToDate = status else { Issue.record("expected .upToDate, got \(status)"); return }
        #expect(transport.uploadCallCount == 1)
    }

    @Test func statisticsAggregatePayloadEncodesOnKueMac() throws {
        let payload = StatisticsAggregatePayload.make(from: .empty, bucketStart: .now, calendar: .current)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(StatisticsAggregatePayload.self, from: data)
        #expect(decoded == payload)
    }
}
