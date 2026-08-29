//
//  KueTypography.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. Semantic text roles, every one built on a system
//  `Font.TextStyle` (never a fixed point size — requirement 7/8: "prefer system typography
//  and Dynamic Type-compatible styles," "do not hardcode fixed font sizes for important
//  content"). Naming these by *role* (screenTitle, cardTitle, statusLabel, ...) rather than
//  by size means a screen never has to know or care what point size "cardTitle" resolves to
//  at a given Dynamic Type setting — it just asks for the role.
//
//  Every one of these already scales with the user's Dynamic Type setting for free (system
//  `Font.TextStyle` does that automatically); none needs `.dynamicTypeSize` or a manual
//  scaling factor.
//

import SwiftUI

enum KueTypography {
    /// A NavigationStack's own large/inline title — Home, Settings.
    static let screenTitle = Font.system(.largeTitle, weight: .bold)
    /// A card/row's primary text — event titles in `EventCard`, section headers' leading text.
    static let cardTitle = Font.system(.headline, weight: .semibold)
    /// A card/row's secondary line — date/type/subtitle text.
    static let cardSubtitle = Font.system(.subheadline)
    /// Small status text — badges, pills, timestamps next to a badge.
    static let statusLabel = Font.system(.caption, weight: .semibold)
    /// Section headers inside a `List`/`Form` (the default is already Dynamic Type-safe;
    /// named here so call sites read intentionally rather than reaching for a bare `.headline`).
    static let sectionHeader = Font.system(.subheadline, weight: .semibold)
    /// Footnote/help text under a control.
    static let footnote = Font.system(.footnote)
    /// Body copy — form fields, notes, disclosure text.
    static let body = Font.system(.body)
    /// A large numeric/glanceable readout — countdown-style numbers, duration displays.
    static let metric = Font.system(.title2, weight: .bold).monospacedDigit()
}

extension View {
    /// Convenience so call sites read `.kueFont(.cardTitle)` next to other `.kue*` modifiers,
    /// rather than mixing `.font(KueTypography.cardTitle)` in among them.
    func kueFont(_ font: Font) -> some View {
        self.font(font)
    }
}
