//
//  KueColor.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. Semantic color roles, built entirely on system dynamic
//  colors (`Color.primary`/`.secondary`, `Color(uiColor: .systemBackground)`, and the
//  standard system status hues) — never a hand-picked hex value. System colors already
//  adapt to light/dark, Increased Contrast, and (via `Color.primary`/`.secondary`'s own
//  vibrancy) sit correctly on top of both opaque and glass backgrounds, which a hardcoded
//  color can't guarantee.
//
//  Status colors are always paired with an icon and a text label at every call site in this
//  app (see `KueStatusStyle`) — never the only way a state is conveyed (requirement 39).
//

import SwiftUI
import UIKit

enum KueColor {
    // MARK: - Foreground hierarchy

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    /// Tertiary text — de-emphasized captions (task offset labels, timestamps).
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let disabledText = Color(uiColor: .quaternaryLabel)

    // MARK: - Backgrounds (opaque — the Reduce Transparency fallback target; see KueGlass.swift)

    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    static let surfaceBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurfaceBackground = Color(uiColor: .tertiarySystemGroupedBackground)

    // MARK: - Separators

    static let separator = Color(uiColor: .separator)

    // MARK: - Brand / primary action

    static let accent = Color.accentColor

    // MARK: - Status semantics (requirement 4: "error, warning, success, active, urgent,
    // completed, and disabled states")

    /// An event currently in progress.
    static let active = Color.blue
    /// Needs attention soon — today/tomorrow, low-confidence recognition, etc.
    static let urgent = Color.orange
    /// Done — completed tasks/events.
    static let completed = Color.green
    /// A recoverable problem the user should notice but isn't blocking.
    static let warning = Color.orange
    /// A blocking problem — validation failures, permission denials.
    static let error = Color.red
    /// A positive confirmation (distinct from `completed` — used for one-off confirmations
    /// like "saved," not a persistent event state).
    static let success = Color.green
    /// Disabled controls / cancelled-and-greyed content.
    static let disabled = Color.secondary
    /// Recording / actively-capturing indicator (Voice) — visually distinct from `active` so
    /// "an event is in progress" and "the mic is live" are never confusable at a glance.
    static let recording = Color.red
}
