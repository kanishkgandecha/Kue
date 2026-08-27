//
//  KueIconSize.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System. Semantic SF Symbol point sizes. Uses `.imageScale`
//  where possible (it already tracks Dynamic Type); the explicit point sizes here are only
//  for standalone glyphs that aren't attached to adjacent Dynamic-Type text (empty-state
//  icons, large status glyphs), where a fixed *base* size the system still nudges via
//  `.dynamicTypeSize` scaling is appropriate — never for icons that sit inline with text,
//  which should use `.imageScale` instead so they track that text's own size exactly.
//

import Foundation

enum KueIconSize {
    /// Inline with a caption/footnote (status pills, row accessories).
    static let small: CGFloat = 14
    /// Inline with body/headline text (list row leading icons).
    static let medium: CGFloat = 20
    /// A standalone glyph — card header icon, prominent action icon.
    static let large: CGFloat = 32
    /// Empty-state / large disclosure icons.
    static let extraLarge: CGFloat = 44
}
