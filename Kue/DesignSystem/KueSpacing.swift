//
//  KueSpacing.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. See docs/21-design-system.md "Spacing" for the full
//  rationale. A small, semantic spacing scale — every layout distance in the redesigned
//  screens should come from here, never a bare numeric literal, so a future adjustment to
//  "how much room things get" is a one-line change instead of a grep-and-replace.
//
//  Values are a classic 4pt-based scale (Apple's own system spacing steps in the same
//  neighborhood) — chosen for familiarity, not novelty; this file's job is naming, not
//  invention.
//

import Foundation

enum KueSpacing {
    /// Tightest — between an icon and its immediately-adjacent label, e.g.
    static let xxs: CGFloat = 2
    /// Between closely related elements within one row (icon–title gap).
    static let xs: CGFloat = 4
    /// Between a title and its subtitle/caption within one card/row.
    static let sm: CGFloat = 8
    /// The default gap between sibling controls in a form row or HStack.
    static let md: CGFloat = 12
    /// Between distinct rows/cards within a section.
    static let lg: CGFloat = 16
    /// Between sections, and standard screen-edge content margins.
    static let xl: CGFloat = 24
    /// Between major page regions (e.g. above a floating primary action).
    static let xxl: CGFloat = 32
}
