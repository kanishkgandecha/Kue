//
//  FakeSpotlightIndexer.swift
//  Kue
//
//  Deterministic in-memory `SpotlightIndexing` — no real Core Spotlight call anywhere, so
//  `KueTests`/`KueUITests` never touch the device's actual on-disk search index. Same
//  "@MainActor final class, launch-argument-gated" shape `FakeLiveActivityManager` (Phase 9)
//  established.
//

import Foundation

@MainActor
final class FakeSpotlightIndexer: SpotlightIndexing {
    /// Must match `UITestLaunchConfiguration.fakeSpotlightArgument` (KueUITests/) exactly.
    static let uiTestLaunchArgument = "-uiTestFakeSpotlight"

    static func makeFromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeSpotlightIndexer? {
        guard arguments.contains(uiTestLaunchArgument) else { return nil }
        return FakeSpotlightIndexer()
    }

    private(set) var indexedPayloads: [UUID: SpotlightEventPayload] = [:]
    private(set) var indexCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var removeAllCallCount = 0

    func index(_ payloads: [SpotlightEventPayload]) async {
        indexCallCount += 1
        for payload in payloads {
            indexedPayloads[payload.eventID] = payload
        }
    }

    func remove(eventIDs: [UUID]) async {
        removeCallCount += 1
        for id in eventIDs {
            indexedPayloads.removeValue(forKey: id)
        }
    }

    func removeAll() async {
        removeAllCallCount += 1
        indexedPayloads.removeAll()
    }

    /// Test convenience — resets every recorded call/state between cases in the same file.
    func reset() {
        indexedPayloads.removeAll()
        indexCallCount = 0
        removeCallCount = 0
        removeAllCallCount = 0
    }
}
