//
//  MacAppState.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — the one shared piece of UI-only state `KueMacApp` hands to both
//  `RootSplitView` (acts on it) and `KueMacCommands` (reads/writes it) so menu commands can
//  reach the currently-shown window without SwiftUI's `Commands`/window-content environments
//  needing to line up — a plain shared reference, not a second copy of anything. Holds no
//  domain data itself (no events, no drafts) — just "what did the menu just ask for" and
//  "what's currently selected," both already transient view state on the iOS side too.
//

import Foundation
import Observation

@Observable
final class MacAppState {
    enum PendingCommand: Equatable {
        case newEvent
        case search
        case showHome, showToday, showUpcoming, showNeedsReview
        case deleteSelectedEvent
        case exportBackup, restoreBackup
        case showOnboarding
        case importFromCalendar
    }

    var selectedEventID: UUID?
    var pendingCommand: PendingCommand?

    var hasSelection: Bool { selectedEventID != nil }
}
