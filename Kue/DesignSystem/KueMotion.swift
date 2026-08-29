//
//  KueMotion.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System, requirement 29/30/31: "restrained motion," "must not be
//  required to understand a state change," "respect Reduce Motion with appropriate
//  alternatives." Every animated transition in the redesign should route through
//  `View.kueAnimation(_:reduceMotion:)` (or the plain `KueMotion.animation(reduceMotion:)`
//  accessor for non-View call sites) rather than a bare `.animation(.spring(...))` literal —
//  one place decides both "what the standard motion feels like" and "what happens when
//  Reduce Motion is on," so no call site can forget the second half.
//
//  Reduce Motion here means "replace spring/slide motion with a fast, simple crossfade," not
//  "remove the transition and let content jump" — content must still be understandable
//  without motion (every state change this app makes is *also* conveyed by a label/icon/text
//  change, never motion alone), but a state change disappearing with zero transition at all
//  reads as a glitch, not a respectful accessibility accommodation.
//

import SwiftUI

enum KueMotion {
    /// The standard "something changed" animation — list insertions/removals, progress
    /// updates, confirmation banners.
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// A quicker variant for frequent, small updates (recording duration ticks, live
    /// transcript growth) where the standard spring would feel sluggish if it re-triggered
    /// every second.
    static let quick = Animation.easeOut(duration: 0.18)
    /// Reduce Motion's replacement for either of the above — a plain, short crossfade.
    static let reduced = Animation.easeInOut(duration: 0.12)

    /// Resolves to `standard`/`quick` unless `reduceMotion` is set, in which case every
    /// animation collapses to the same simple `reduced` crossfade — the actual motion *style*
    /// difference (spring vs. linear) is exactly what Reduce Motion asks to remove; the state
    /// change itself still animates (a hard cut is jarring, not "reduced").
    static func animation(_ base: Animation = standard, reduceMotion: Bool) -> Animation? {
        reduceMotion ? reduced : base
    }
}

extension View {
    /// `reduceMotion` is threaded explicitly (not read via `@Environment` inside this
    /// extension) so it composes with `@Environment(\.accessibilityReduceMotion)` read once at
    /// the call site, matching how the rest of this design system takes accessibility state as
    /// a parameter rather than each leaf re-reading the environment.
    func kueAnimation(_ base: Animation = KueMotion.standard, reduceMotion: Bool, value: some Equatable) -> some View {
        animation(KueMotion.animation(base, reduceMotion: reduceMotion), value: value)
    }
}
