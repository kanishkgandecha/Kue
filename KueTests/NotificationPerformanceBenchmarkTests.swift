//
//  NotificationPerformanceBenchmarkTests.swift
//  KueTests
//
//  Kue 3.0 Phase 3 completion pass — docs/31 "Capacity and prioritization" / "Performance":
//  the missing deterministic planner benchmark/stress coverage this pass's own review flagged
//  as absent. A fixed, non-random fixture (same event/rule counts every run, strictly
//  increasing start dates) so a regression shows up as a real behavioral change, not
//  fixture-to-fixture noise — same discipline `MacPerformanceBenchmarkTests.swift` already
//  established for the general app-data benchmark, just scoped to
//  `NotificationPlanner`/`NotificationExecutor` specifically.
//
//  Every `#expect` in this file asserts a deterministic, timing-independent property (count,
//  set membership, ordering, identifier preservation) — elapsed time is measured with
//  `ContinuousClock` and only ever printed, never gated with `#expect(duration < ...)`. This is
//  a deliberate, stricter split than this codebase's own pre-existing Mac benchmark (which does
//  assert generous upper bounds as a coarse regression guard) — this pass's own instructions
//  ask specifically for "no flaky wall-clock assertions as a correctness gate," so the new file
//  here holds to that line exactly rather than retrofitting the older one.
//

import Testing
import Foundation
import UserNotifications
@testable import Kue

@MainActor
struct NotificationPerformanceBenchmarkTests {
    /// Deterministic, not random. 3,000 events — comfortably "thousands," per this pass's own
    /// requirement — a third of them carrying their own enabled event-level rule (so the rule
    /// layer, not just the default layer, is exercised at scale), a third carrying a *disabled*
    /// rule (exercises `.ruleDisabled` exclusion at scale), and the rest rule-free (default
    /// layer only).
    private static let eventCount = 3000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Strictly increasing `startDate` (index 0 soonest) — this is what makes "the nearest-
    /// dated N survive capacity" a checkable, deterministic property at this scale, the exact
    /// same property `NotificationPlannerTests.capacityLimitExcludesTheFurthestOutCandidatesWithATypedReason`
    /// already checks at a small scale.
    private func makeFixture() -> [KueEvent] {
        var events: [KueEvent] = []
        events.reserveCapacity(Self.eventCount)
        for i in 0..<Self.eventCount {
            let event = KueEvent(
                title: "Benchmark Event \(i)", eventType: .generic,
                startDate: now.addingTimeInterval(Double(i + 1) * 3600), estimatedDurationMinutes: 60,
                timeZoneIdentifier: "UTC", source: .manual
            )
            switch i % 3 {
            case 0:
                event.notificationRules = [NotificationRule(event: event, anchor: .eventStart, offsetDirection: .before, offsetQuantity: 15, offsetUnit: .minutes)]
            case 1:
                event.notificationRules = [NotificationRule(event: event, anchor: .eventStart, isEnabled: false)]
            default:
                break // default layer only
            }
            events.append(event)
        }
        return events
    }

    private func planInput(events: [KueEvent], capacity: Int) -> NotificationPlanner.Input {
        NotificationPlanner.Input(events: events, globalPreferences: .conservativeDefault, intensity: .standard, authorizationGranted: true, now: now, capacity: capacity)
    }

    // MARK: - Deterministic correctness (no timing involved at all)

    @Test func planningThousandsOfEventsProducesExactlyTheCapacityLimitedCountEveryTime() {
        let events = makeFixture()
        let first = NotificationPlanner.plan(planInput(events: events, capacity: 64))
        let second = NotificationPlanner.plan(planInput(events: events, capacity: 64))

        #expect(first.scheduledCandidates.count == 64)
        // Deterministic repeatability — this pass's own explicit requirement — identical
        // input plans to the identical ordered identifier list every time.
        #expect(first.scheduledCandidates.map(\.identifier) == second.scheduledCandidates.map(\.identifier))
    }

    /// The documented capacity contract (docs/31 "Capacity and prioritization"): with every
    /// candidate at equal priority, the tie-break is effective delivery date ascending — so
    /// with strictly increasing start dates, the 64 nearest-dated events' candidates survive
    /// and every later one is excluded for capacity. Same property
    /// `capacityLimitExcludesTheFurthestOutCandidatesWithATypedReason` already checks at n=10;
    /// this is the identical check at n=3,000.
    @Test func capacityOrderingKeepsTheNearestDatedCandidatesAtScale() {
        let events = makeFixture()
        let result = NotificationPlanner.plan(planInput(events: events, capacity: 64))

        #expect(result.scheduledCandidates.contains { $0.eventID == events[0].id })
        #expect(!result.scheduledCandidates.contains { $0.eventID == events[Self.eventCount - 1].id })
        #expect(result.excludedCandidates.contains { $0.reason == .systemCapacityLimit })
    }

    /// "Every scheduled or excluded candidate is accounted for" — capacity trimming never
    /// silently drops a candidate; it always becomes either a scheduled one or a typed
    /// `.systemCapacityLimit` exclusion. Verified by comparing against an uncapped plan (a
    /// very large capacity effectively disables trimming) covering the exact same input.
    @Test func everyUncappedCandidateIsAccountedForAfterCapacityTrimming() {
        let events = makeFixture()
        let uncapped = NotificationPlanner.plan(planInput(events: events, capacity: 1_000_000))
        let capped = NotificationPlanner.plan(planInput(events: events, capacity: 64))

        let uncappedIdentifiers = Set(uncapped.scheduledCandidates.map(\.identifier))
        let cappedIdentifiers = Set(capped.scheduledCandidates.map(\.identifier))
        let capacityExcludedIdentifiers = Set(capped.excludedCandidates.filter { $0.reason == .systemCapacityLimit }.map(\.identifier))

        #expect(cappedIdentifiers.isSubset(of: uncappedIdentifiers))
        #expect(cappedIdentifiers.union(capacityExcludedIdentifiers) == uncappedIdentifiers)
        #expect(capped.scheduledCandidates.count + capacityExcludedIdentifiers.count == uncapped.scheduledCandidates.count)
    }

    /// Every event with a disabled rule (a third of the fixture) produces a `.ruleDisabled`
    /// exclusion — exclusion-generation exercised at scale, not just scheduling.
    @Test func disabledRulesAcrossTheFullFixtureAllProduceTypedExclusions() {
        let events = makeFixture()
        let disabledRuleEvents = events.enumerated().filter { $0.offset % 3 == 1 }.map(\.element)
        let result = NotificationPlanner.plan(planInput(events: events, capacity: 1_000_000))

        let disabledExclusionCount = result.excludedCandidates.filter { $0.reason == .ruleDisabled }.count
        #expect(disabledExclusionCount == disabledRuleEvents.count)
    }

    /// Reconciliation at scale never touches a pending identifier outside its own known set —
    /// the exact same property `NotificationExecutorTests.reconcileNeverRemovesAPendingIdentifierOutsideItsKnownSet`
    /// already checks with a handful of requests, now with thousands of Kue-owned ones
    /// alongside a genuinely unrelated one.
    @Test func reconciliationAtScaleNeverRemovesAnIdentifierOutsideItsKnownSet() async {
        let events = makeFixture()
        let plan = NotificationPlanner.plan(planInput(events: events, capacity: 64))
        let scheduler = FakeNotificationScheduler()
        await scheduler.add(UNNotificationRequest(identifier: "totally-unrelated-app-identifier", content: .init(), trigger: nil))

        let knownIdentifiers = Set(events.flatMap { event in
            NotificationCandidateBuilder.allIdentifiers(for: event) + event.notificationRules.map { "\(event.id)-rule-\($0.id)" }
        })
        let result = await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: knownIdentifiers, scheduler: scheduler, globalPreferences: .conservativeDefault)

        #expect(result.added.count == 64)
        #expect(await scheduler.pendingRequestIdentifiers().contains("totally-unrelated-app-identifier"))
    }

    // MARK: - Informational performance measurement (never a pass/fail gate)

    /// Prints dataset size, rule/candidate counts, and elapsed time for planning, exclusion
    /// generation, and reconciliation — the exact evidence this pass's own review asked for.
    /// No `#expect` here ever inspects `duration` — see this file's own header.
    @Test func measuredPlanningAndReconciliationPerformanceAtScale() async {
        let clock = ContinuousClock()
        let events = makeFixture()
        let ruleCount = events.reduce(0) { $0 + $1.notificationRules.count }

        var plan = NotificationSchedulePlan.empty
        let planDuration = clock.measure {
            plan = NotificationPlanner.plan(planInput(events: events, capacity: 64))
        }

        let scheduler = FakeNotificationScheduler()
        let knownIdentifiers = Set(events.flatMap { event in
            NotificationCandidateBuilder.allIdentifiers(for: event) + event.notificationRules.map { "\(event.id)-rule-\($0.id)" }
        })
        let reconcileStart = clock.now
        _ = await NotificationExecutor.reconcile(plan: plan, knownIdentifiers: knownIdentifiers, scheduler: scheduler, globalPreferences: .conservativeDefault)
        let reconcileDuration = clock.now - reconcileStart

        print("[Notification Benchmark] Dataset: \(Self.eventCount) events, \(ruleCount) explicit rules")
        print("[Notification Benchmark] Plan output: \(plan.scheduledCandidates.count) selected, \(plan.excludedCandidates.count) excluded")
        print("[Notification Benchmark] NotificationPlanner.plan elapsed: \(planDuration)")
        print("[Notification Benchmark] NotificationExecutor.reconcile elapsed: \(reconcileDuration)")

        // The only assertions here are the same deterministic ones as above, restated to keep
        // this test meaningful even if someone reads only its pass/fail result — never a
        // duration-based one.
        #expect(plan.scheduledCandidates.count == 64)
        #expect(await scheduler.pendingRequestIdentifiers().count == 64)
    }
}
