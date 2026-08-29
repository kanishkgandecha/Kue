//
//  LiveActivityLockScreenAccentTests.swift
//  KueTests
//
//  Post-Phase-12 fix — Lock Screen visual redesign (docs/23 "K."). Focused, pure unit tests for
//  the accent-color mapping the redesign introduced.
//
//  Scope note: `KueWidget/` (where `activeAccentColor(eventType:state:)` and `ContentState`
//  live, in `LiveActivitySharedHelpers.swift`) compiles into the `KueWidget` extension target,
//  NOT the `Kue` app target — `@testable import Kue` from this file structurally cannot see
//  either symbol. This project has no `KueWidgetTests`-style target to reach them from, and one
//  is not being added here. So only `EventTypeAccent.color(for:)` (in `Shared/DesignSystem/
//  EventTypeAccent.swift`, which does compile into `Kue`) is covered below.
//  `activeAccentColor`'s own logic — return `.red` when genuinely tracking and urgent and not
//  completed/removed, otherwise `EventTypeAccent.color(for:)` — is simple/inspectable by
//  reading `LiveActivitySharedHelpers.swift` directly and is intentionally left untested by
//  XCTest/Swift Testing here rather than faked out through a parallel, non-real type.
//

import Testing
import SwiftUI
@testable import Kue

@MainActor
struct LiveActivityLockScreenAccentTests {
    @Test func everyEventTypeGetsADistinctAccentColor() {
        let colors = EventType.allCases.map { EventTypeAccent.color(for: $0) }
        for i in colors.indices {
            for j in colors.indices where j > i {
                #expect(colors[i] != colors[j], "\(EventType.allCases[i]) and \(EventType.allCases[j]) must not share an accent color")
            }
        }
    }

    /// `EventType`'s switch in `EventTypeAccent.color(for:)` is exhaustive today, so `unknown`
    /// is never actually returned by that function — it exists as the fallback a future/foreign
    /// case would need. This just proves it's a real, distinct, safe value to fall back to.
    @Test func unknownFallbackIsDistinctFromEveryRealEventTypeAccent() {
        let realColors = EventType.allCases.map { EventTypeAccent.color(for: $0) }
        for color in realColors {
            #expect(EventTypeAccent.unknown != color)
        }
    }
}
