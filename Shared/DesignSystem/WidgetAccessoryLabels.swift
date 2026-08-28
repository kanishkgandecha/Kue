//
//  WidgetAccessoryLabels.swift
//  Kue
//
//  See docs/22-expanded-and-dedicated-widgets.md "G. Design system in WidgetKit" / "H.
//  Privacy" — the only pieces of Phase 7's design system genuinely safe to share into a
//  widget-extension target: pure string formatting, no SwiftUI `Color`/`Font` (those stay in
//  `Kue/DesignSystem/`, which does not compile into `KueWidget`).
//

import Foundation

enum WidgetAccessoryLabels {
    /// The one status string every accessory family (`.accessoryCircular`/
    /// `.accessoryRectangular`/`.accessoryInline`) and its accessibility label may use —
    /// **never** `WidgetDisplayContent.subline` directly. `subline` is phase-dependent and,
    /// for `.preparation`/`.tomorrow` (the next incomplete task's *title*) and `.today` (the
    /// event's *location*, when `showLocation` is on), carries exactly the "task details" /
    /// "location" content requirement H says accessory families must never expose — Lock
    /// Screen/StandBy are ambient-visible to anyone near the device, not just its owner. Only
    /// `.countdown`'s subline is safe to reuse (it's already just a day count), compacted via
    /// `compactCountdown` below; every other phase gets a fixed, generic word instead.
    static func accessorySafeStatus(phase: WidgetLifecyclePhase, subline: String?) -> String {
        switch phase {
        case .countdown: return compactCountdown(fromSubline: subline)
        case .preparation: return "Preparing"
        case .tomorrow: return "Tomorrow"
        case .today: return "Today"
        case .awaitingOutcome: return "Needs Review"
        case .completed: return "Completed"
        case .removed: return "Archived"
        }
    }

    /// Compacts a deterministic day-count string ("3 days," "1 day" — `.countdown`'s subline
    /// only) into a short accessory-friendly form ("3d") — never recomputes the day count
    /// itself; `subline` is the one source of truth for that number (docs/22 "F.": "one
    /// source of truth, never a second countdown calculation"). `private` — only
    /// `accessorySafeStatus` above should call this, so a caller can never accidentally pass
    /// a *different* phase's (potentially sensitive) subline through it.
    private static func compactCountdown(fromSubline subline: String?) -> String {
        guard let subline else { return "—" }
        let digits = subline.prefix { $0.isNumber }
        guard !digits.isEmpty else { return subline }
        return "\(digits)d"
    }
}
