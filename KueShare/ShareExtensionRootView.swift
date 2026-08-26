//
//  ShareExtensionRootView.swift
//  KueShare
//
//  See docs/09-screens-and-ux.md "Confirmation / ambiguity UI" and docs/13-error-
//  handling.md "Network failure" / "Parse failure". Requirement 3: shared content routes
//  through the *same* `NLParsingPipeline` (Kue/Services/, reused verbatim — see that file's
//  header) and the *same* `EventFormView` confirmation sheet typed NL input uses; requirement
//  5: nothing is persisted until that sheet's own "Create" button runs `EventFormView.save()`
//  — this file never touches `ModelContext` directly, only supplies the `.modelContainer`
//  environment `EventFormView` (and its `@Query`-based duplicate check) needs. Requirement 7:
//  cancellation/failure both route to the identical pre-filled manual form, never a partial
//  write.
//

import SwiftUI
import SwiftData

@available(iOS 26.0, *)
struct ShareExtensionRootView: View {
    let providers: [ShareItemProviding]
    /// Fires once, whichever way the sheet closes (Create *or* Cancel) — from the host app's
    /// (Safari/Mail/Messages) perspective the share interaction is simply over either way;
    /// nothing partial was ever written regardless of which button was tapped.
    let onFinish: () -> Void

    private let parser: NLParsing
    private let availabilityChecker: AIAvailabilityChecking
    private let urlFetcher: URLContentFetching
    private let container: ModelContainer?

    @State private var isPresentingForm = false
    @State private var formInput: FormInput?
    @State private var pendingMessage: String?
    /// True once the pending alert's own dismissal should end the whole flow (no shared
    /// store to persist into at all) rather than lead into the form.
    @State private var isStoreUnavailable = false

    /// What `EventFormView(prefilledDraft:ambiguities:source:)` needs — bundled together so
    /// the sheet's content closure never has to force-unwrap three separate optionals.
    private struct FormInput {
        var draft: EventDraft
        var ambiguities: [DraftAmbiguity]
        var source: EventSource
    }

    /// No default values for `parser`/`availabilityChecker`/`container` — each is either a
    /// `@MainActor` type or a `MainActor`-isolated-by-default static function (see AGENTS.md
    /// "module-wide concurrency quirk"), and default-argument *expressions* are
    /// isolation-checked independently of where the initializer itself runs. `ShareViewController`
    /// constructs the real ones explicitly instead.
    init(
        providers: [ShareItemProviding],
        parser: NLParsing,
        availabilityChecker: AIAvailabilityChecking,
        urlFetcher: URLContentFetching = SystemURLContentFetcher.shared,
        container: ModelContainer?,
        onFinish: @escaping () -> Void
    ) {
        self.providers = providers
        self.parser = parser
        self.availabilityChecker = availabilityChecker
        self.urlFetcher = urlFetcher
        self.container = container
        self.onFinish = onFinish
    }

    var body: some View {
        Color.clear
            .task { await load() }
            .sheet(isPresented: $isPresentingForm, onDismiss: onFinish) {
                if let formInput, let container {
                    EventFormView(prefilledDraft: formInput.draft, ambiguities: formInput.ambiguities, source: formInput.source)
                        .modelContainer(container)
                }
            }
            .alert("Can't Use That Yet", isPresented: Binding(
                get: { pendingMessage != nil },
                set: { if !$0 { pendingMessage = nil } }
            ), presenting: pendingMessage) { _ in
                Button("OK") {
                    if isStoreUnavailable {
                        onFinish()
                    } else {
                        isPresentingForm = true
                    }
                }
            } message: { message in
                Text(message)
            }
    }

    private func load() async {
        guard container != nil else {
            // docs/13-error-handling.md "Widget refresh failure" applies the same principle
            // here: degrade gracefully, never crash the extension process over a broken
            // shared store.
            isStoreUnavailable = true
            pendingMessage = "Kue's shared data isn't available right now — try again from the Kue app."
            return
        }

        let attachments = await ShareContentLoader.loadAll(providers)
        switch ShareContentNormalizer.normalize(attachments) {
        case .url(let url):
            if let title = await urlFetcher.fetchTitle(for: url) {
                await parseAndPresent(text: title)
            } else {
                // docs/13-error-handling.md "Network failure" — exact required copy.
                presentFallback(message: "Can't reach that link — add this manually instead", initialTitle: url.absoluteString)
            }
        case .text(let text):
            await parseAndPresent(text: text)
        case .unsupported:
            presentFallback(message: "This kind of content isn't supported yet — add it manually instead", initialTitle: "")
        case .loadFailed:
            presentFallback(message: "Couldn't read what was shared — add this manually instead", initialTitle: "")
        }
    }

    private func parseAndPresent(text: String) async {
        // docs/03-data-model.md `UserPreference.aiParsingEnabled` — a user choice, checked
        // silently (no alert) since the user explicitly opted out; not the same as a
        // hardware/OS *unavailability* state below.
        if let container, UserPreferenceStore.current(context: ModelContext(container)).aiParsingEnabled == false {
            var draft = EventDraft()
            draft.title = text
            formInput = FormInput(draft: draft, ambiguities: [], source: .manual)
            isPresentingForm = true
            return
        }

        let availability = availabilityChecker.currentAvailability()
        guard availability.isAvailable else {
            // Same per-state copy the Add screen's NL entry point uses — docs/06-ai-layer.md
            // "Runtime availability".
            presentFallback(message: availability.message ?? "AI text parsing isn't available on this device — add it manually instead", initialTitle: text)
            return
        }

        let outcome = await NLParsingPipeline.run(text: text, parser: parser, timeZoneIdentifier: TimeZone.current.identifier)
        if let draft = outcome.draft {
            formInput = FormInput(draft: draft, ambiguities: outcome.ambiguities, source: .shareSheet)
            isPresentingForm = true
        } else {
            presentFallback(message: outcome.failureMessage ?? "Couldn't quite parse that — try rephrasing, or fill it in manually", initialTitle: text)
        }
    }

    /// docs/13-error-handling.md: every failure path "falls back to manual entry, preserving
    /// whatever raw title/text the share payload already had" — never discarded, never a
    /// silently partial event (nothing is persisted until the fallback form's own Create).
    private func presentFallback(message: String, initialTitle: String) {
        var draft = EventDraft()
        draft.title = initialTitle
        formInput = FormInput(draft: draft, ambiguities: [], source: .manual)
        pendingMessage = message
    }
}
