//
//  KueRadius.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. Semantic corner-radius scale. Liquid Glass surfaces
//  generally want a "capsule-ish" continuous curve at small sizes and a softer rounded-rect
//  at card size — these two values cover both without every call site picking its own number.
//

import Foundation

enum KueRadius {
    /// Small controls — badges, chips, compact status pills.
    static let control: CGFloat = 10
    /// Cards, rows, and glass surfaces at "card" scale (Home event cards, banners).
    static let card: CGFloat = 16
    /// Large presentation surfaces — sheet-top corners, prominent floating containers.
    static let surface: CGFloat = 22
}
