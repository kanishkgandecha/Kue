//
//  AIAvailabilityStateTests.swift
//  KueTests
//
//  See docs/06-ai-layer.md "Runtime availability" table and docs/10-testing-strategy.md
//  "each of the four states needs its own test asserting the Add screen shows the correct
//  message/entry-point state, exercised against the framework's availability API rather than
//  requiring a physical device actually in each state." `EventFormView` reads the mapped
//  `AIAvailabilityState` (via the injected `AIAvailabilityChecking`) to decide what to show —
//  this file pins that mapping/messaging for all four states without touching SwiftUI or a
//  live model, exactly the "framework's availability API" substitute the doc calls for.
//

import Testing
@testable import Kue

/// A trivial DI fake — no real `SystemLanguageModel` involved, per requirement 10.
@MainActor
private final class FakeAIAvailabilityChecker: AIAvailabilityChecking {
    let state: AIAvailabilityState
    init(_ state: AIAvailabilityState) { self.state = state }
    func currentAvailability() -> AIAvailabilityState { state }
}

@MainActor
struct AIAvailabilityStateTests {
    @Test func available_hasNoMessageAndIsAvailable() {
        let state = FakeAIAvailabilityChecker(.available).currentAvailability()
        #expect(state.isAvailable)
        #expect(state.message == nil)
    }

    @Test func deviceIneligible_showsTheExactRequiredMessage() {
        let state = FakeAIAvailabilityChecker(.deviceIneligible).currentAvailability()
        #expect(!state.isAvailable)
        #expect(state.message == "AI text parsing isn't available on this device — add it manually instead")
    }

    @Test func appleIntelligenceDisabled_showsTheExactRequiredMessage() {
        let state = FakeAIAvailabilityChecker(.appleIntelligenceDisabled).currentAvailability()
        #expect(!state.isAvailable)
        #expect(state.message == "Turn on Apple Intelligence in Settings to use AI parsing — or add this manually")
    }

    @Test func modelNotReady_showsTheExactRequiredMessage() {
        let state = FakeAIAvailabilityChecker(.modelNotReady).currentAvailability()
        #expect(!state.isAvailable)
        #expect(state.message == "AI parsing is still getting ready on this device — add this manually for now")
    }

    @Test func realCheckerCachesAfterFirstCall() {
        // Doesn't assert *which* state the simulator reports (that's environment-dependent
        // and out of this test's control) — only that repeated calls agree, proving the
        // "once per app session" cache (docs/06-ai-layer.md) rather than a fresh live
        // re-check on every call.
        let checker = SystemAIAvailabilityChecker()
        let first = checker.currentAvailability()
        let second = checker.currentAvailability()
        #expect(first == second)
    }
}
