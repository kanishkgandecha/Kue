//
//  KueGlass.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System, requirement 9-12: adopt native Liquid Glass where it
//  belongs (controls, toolbars, floating actions, compact status surfaces), never force it
//  onto dense content, and always provide a working fallback when the preferred treatment is
//  unavailable or reduced.
//
//  Two distinct cases this file covers:
//   1. Native *controls* — `Button`, `Menu`, toolbar items, sheets — already get Liquid Glass
//      automatically from the system's own `.glass`/`.glassProminent` button styles and
//      standard toolbar/navigation chrome; those call sites use the system APIs directly
//      (see EventFormView/HomeView/etc.) and need nothing from this file, because iOS itself
//      already handles their Reduce Transparency fallback.
//   2. App-composited *surfaces* — a custom card, banner, or floating container this app draws
//      its own background for — where *we* choose the material, so *we* own the fallback.
//      `View.kueGlassSurface(...)` below is that one shared choice: native `.glassEffect`
//      when transparency is allowed, a fully opaque semantic background (never just "blur
//      removed, content left translucent" — requirement 12) when it isn't.
//

import SwiftUI

/// Requirement 12 — "replace translucent surfaces with sufficiently opaque semantic
/// backgrounds... preserve hierarchy... do not merely remove blur and leave unreadable
/// content." One shared modifier so every app-composited glass surface gets this exact
/// contract, not a bespoke per-view `if reduceTransparency` branch that might forget it.
private struct KueGlassSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tint: Color?
    var shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(KueColor.elevatedSurfaceBackground, in: shape)
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        }
    }
}

extension View {
    /// The one reusable way an app-composited surface (a card, banner, or floating container
    /// this view draws its own background for) opts into Liquid Glass, with the Reduce
    /// Transparency fallback built in. `shape` defaults to `KueRadius.card`'s rounded
    /// rectangle — the size most of these surfaces actually are.
    func kueGlassSurface(tint: Color? = nil, in shape: some Shape = RoundedRectangle(cornerRadius: KueRadius.card, style: .continuous)) -> some View {
        modifier(KueGlassSurfaceModifier(tint: tint, shape: shape))
    }

    /// The compact variant for pill/badge-scale surfaces (status chips, capsule buttons).
    func kueGlassPill(tint: Color? = nil) -> some View {
        modifier(KueGlassSurfaceModifier(tint: tint, shape: Capsule(style: .continuous)))
    }
}
