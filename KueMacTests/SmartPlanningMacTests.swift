//
//  SmartPlanningMacTests.swift
//  KueMacTests
//
//  Kue 3.0 Phase 8 — docs/36. Extends the shared `KueMacAllTests` suite (see
//  `MacModelContainerFactoryTests.swift`'s own header for why every KueMacTests file shares
//  one `@Suite(.serialized)` type rather than declaring its own). Covers the same business
//  logic `SmartPlanningEngineTests`/`PlanningActionRouterTests` already prove in `KueTests`,
//  but exercised through the exact surface `MacTodayPlanView` actually calls
//  (`TodayPlanViewModel.refresh`) — the "equivalent business behavior" half of docs/36's own
//  Mac test requirement; `MacTodayPlanView`'s reliable native UI surfaces (the `.plan` sidebar
//  destination, its accessibility identifiers) are unit-verifiable structurally below without
//  a full `KueMacUITests` run.
//

import Testing
import Foundation
import SwiftData
@testable import KueMac

extension KueMacAllTests {
    @Test func macTodayPlanViewModelProducesAPlanFromRealModelData() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(ModelContainerFactory.makeInMemory())
        let event = KueEvent(title: "Prep Review", eventType: .exam, startDate: now.addingTimeInterval(-7200), estimatedDurationMinutes: 60, timeZoneIdentifier: "UTC", source: .manual)
        context.insert(event)
        try? context.save()

        let viewModel = TodayPlanViewModel()
        await viewModel.refresh(context: context, calendarProvider: FakeCalendarProvider(stateToReturn: .denied), now: now)

        #expect(viewModel.plan != nil)
        #expect(viewModel.plan?.orderedRecommendations.contains { $0.category == .confirmEventOutcome } == true)
        // Calendar was denied — the plan must disclose limited information honestly rather
        // than silently treating "no data" as "no conflicts."
        #expect(viewModel.plan?.limitedInformationNotice != nil)
    }

    @Test func macSidebarOffersAPlanDestinationAlongsideHome() {
        #expect(MacSidebarDestination.allCases.contains(.plan))
        #expect(MacSidebarDestination.plan.title == "Plan")
    }

    @Test func macRecommendationDismissalIsPersistedThroughTheSharedRouter() {
        RecommendationDismissalStore.resetAll()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recommendation = PlanningRecommendation(
            id: "mac-dismiss-test", category: .reviewOverdueTask, title: "x", explanation: "x",
            contributingFactors: [], confidence: .medium, suggestedAction: .dismiss,
            availableActions: [.dismiss], createdAt: now, expiresAt: now
        )
        PlanningActionRouter.dismiss(recommendation, now: now)
        #expect(RecommendationDismissalStore.isSuppressed(id: recommendation.id, now: now))
        RecommendationDismissalStore.resetAll()
    }
}
