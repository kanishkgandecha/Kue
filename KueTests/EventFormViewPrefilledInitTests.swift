//
//  EventFormViewPrefilledInitTests.swift
//  KueTests
//
//  See EventFormView.swift's `init(prefilledDraft:ambiguities:source:)` header comment —
//  Phase 10 (M9)'s Share Extension entry point into the *same* confirmation workflow typed
//  NL input uses. Constructing a SwiftUI `View` value doesn't require a running app (it's
//  just a value type until rendered), so the initializer's own wiring — which `Mode` it
//  resolves to — is directly checkable here. `draft`/`ambiguities`/`draftSource` are
//  `@State`, not introspectable outside a render pass; the rest of that path (duplicate
//  detection, save/cancel) is the same `EventFormView` code the existing Add-flow UI tests
//  already exercise, not reimplemented for this init.
//

import Testing
@testable import Kue

struct EventFormViewPrefilledInitTests {
    @Test func prefilledInitResolvesAddModeWithTheDraftsEventType() {
        var draft = EventDraft()
        draft.title = "Salesforce Interview"
        draft.eventType = .interview

        let view = EventFormView(prefilledDraft: draft, ambiguities: [], source: .shareSheet)

        guard case .add(let initialEventType) = view.mode else {
            Issue.record("expected .add mode")
            return
        }
        #expect(initialEventType == .interview)
        #expect(view.isEditing == false)
    }
}
