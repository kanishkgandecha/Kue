//
//  KueDesignSystemTests.swift
//  KueTests
//
//  Kue 2.0 Phase 7 — Design System, requirement 44: focused tests for the design-system layer
//  itself, not full-view rendering (SwiftUI view *bodies* aren't practically unit-testable
//  without a UI-testing harness — `KueUITests`' redesigned-flow assertions cover that side).
//  These pin down the pure, testable pieces: the status-mapping logic, the Reduce Motion
//  animation swap, and the haptics abstraction's "never touches real hardware, always records
//  what was asked for" contract (requirement 33/34).
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import UIKit
@testable import Kue

@MainActor
struct KueDesignSystemTests {
    // MARK: - KueStatusStyle (requirement 39: color is never the only signal)

    @Test func everyStatusMappingCarriesALabelAndAnIconAlongsideItsColor() {
        let container = ModelContainerFactory.makeInMemory()
        let event = KueEvent(title: "Test", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual)
        container.mainContext.insert(event)

        for status in EventStatus.allCases {
            let style = KueStatusStyle.forEvent(event, status: status)
            #expect(!style.label.isEmpty)
            #expect(!style.systemImage.isEmpty)
        }
    }

    @Test func aSkippedOccurrenceReadsAsSkippedRegardlessOfDerivedStatus() {
        let container = ModelContainerFactory.makeInMemory()
        let event = KueEvent(title: "Test", eventType: .generic, startDate: .now, estimatedDurationMinutes: 30, source: .manual)
        event.isSkipped = true
        container.mainContext.insert(event)

        // Even if the derived status would otherwise read as "cancelled," the real
        // `isSkipped` field must win — same rule `EventCard`/`EventDetailView` already follow.
        let style = KueStatusStyle.forEvent(event, status: .cancelled)
        #expect(style.label == "Skipped")
    }

    // MARK: - KueMotion (requirement 31: Reduce Motion still animates, just differently)

    @Test func reduceMotionAlwaysResolvesToTheReducedAnimation() {
        #expect(KueMotion.animation(KueMotion.standard, reduceMotion: true) == KueMotion.reduced)
        #expect(KueMotion.animation(KueMotion.quick, reduceMotion: true) == KueMotion.reduced)
    }

    @Test func withoutReduceMotionTheRequestedAnimationIsUsedUnchanged() {
        #expect(KueMotion.animation(KueMotion.standard, reduceMotion: false) == KueMotion.standard)
        #expect(KueMotion.animation(KueMotion.quick, reduceMotion: false) == KueMotion.quick)
    }

    // MARK: - KueGlass fallback target (requirement 12 — see HomeView's own note on why this
    // is checked here rather than via a Reduce-Transparency preview)

    @Test func theGlassFallbackBackgroundIsARealOpaqueSystemColorNotATranslucentOne() {
        // `Color` doesn't expose its own opacity for inspection directly, but every semantic
        // background in this file is built from a `UIColor` system background constant (never
        // `.opacity(...)`) — this pins that contract by construction: resolving the color
        // against a concrete trait collection must not throw/crash and must not be `.clear`.
        let resolved = UIColor(KueColor.elevatedSurfaceBackground).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var alpha: CGFloat = 0
        resolved.getWhite(nil, alpha: &alpha)
        #expect(alpha == 1, "the Reduce Transparency fallback background must be fully opaque")
    }

    // MARK: - KueWordmark (approved asset, light/dark appearance switching)

    @Test func theApprovedWordmarkAssetLoadsFromTheCatalog() {
        // A real, cheap regression check that "KueWordmark" is spelled identically in both the
        // image set and `KueWordmark.swift`'s `Image("KueWordmark")` — catches a rename/typo in
        // either place without needing a UI test.
        #expect(UIImage(named: "KueWordmark") != nil)
    }

    @Test func theWordmarkAssetActuallyDiffersBetweenLightAndDarkAppearance() {
        // Confirms the asset catalog's light/dark variants are really wired in (not just a
        // single image with unused appearance metadata) — resolving the same dynamic asset
        // against opposite trait collections must not just work, but genuinely differ.
        guard let asset = UIImage(named: "KueWordmark")?.imageAsset else {
            Issue.record("KueWordmark image asset not found")
            return
        }
        let light = asset.image(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light.pngData() != dark.pngData())
    }

    // MARK: - KueHaptics (requirement 32/33/34)

    @Test func fakeHapticPlayerRecordsEveryEventWithoutTouchingRealHardware() {
        let player = FakeHapticPlayer()
        player.play(.eventCreated)
        player.play(.destructiveConfirmed)
        #expect(player.playedEvents == [.eventCreated, .destructiveConfirmed])
    }
}
