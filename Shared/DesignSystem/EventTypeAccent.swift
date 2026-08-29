//
//  EventTypeAccent.swift
//  Kue
//
//  Post-Phase-12 fix — Live Activity/Dynamic Island visual redesign. The one shared
//  event-type → accent-color mapper this redesign's own spec calls for ("Add or reuse one
//  shared semantic mapper for event type → Live Activity accent" — no such mapper existed
//  before this file; `Kue/DesignSystem/KueColor.swift` only carries *status* semantics
//  (active/urgent/completed/...), never a per-event-type color, and it doesn't compile into
//  `KueWidget` at all (see `LiveActivityViews.swift`'s own header) — this lives in `Shared/`
//  instead so both the app and the widget extension read the exact same mapping).
//
//  Every value is a named system-semantic `Color` (`.indigo`/`.red`/`.purple`/`.blue`/`.teal`),
//  never a raw hex/RGB literal — system colors already adapt correctly to light/dark mode,
//  Increase Contrast, and tinted/vibrant system materials, which a hand-picked hex value can't
//  guarantee (the same reasoning `KueColor.swift`'s own header already establishes for its own
//  status colors). `EventType` is a small, closed, exhaustive enum
//  (`generic`/`deadline`/`exam`/`interview`/`trip` — Kue's real V1 event types; this feature's
//  own request additionally named "Birthday"/"Appointment"/"Meeting," which do not exist as
//  `EventType` cases in this codebase and were not added — see the final report), so `switch`
//  is exhaustive today; `unknown` exists purely as the safe fallback a future case would need,
//  satisfying "unknown/custom types receive a safe fallback" without speculatively adding
//  cases nothing constructs yet.
//

import SwiftUI

enum EventTypeAccent {
    static func color(for eventType: EventType) -> Color {
        switch eventType {
        case .generic: return .indigo
        case .deadline: return .red
        case .exam: return .purple
        case .interview: return .blue
        case .trip: return .teal
        }
    }

    /// The one fallback every caller should use for a value that can't be mapped above —
    /// there is no such case reachable through `EventType` today, but a caller handed a raw
    /// stored string (e.g. decoding an older/foreign payload) should still have somewhere
    /// safe to land rather than force-unwrapping or guessing.
    static let unknown: Color = .gray
}
