//
//  AIEnvironment.swift
//  Kue
//
//  Dependency injection for the NL parser/availability checker (requirement 10) — views read
//  `\.nlParser`/`\.aiAvailabilityChecker` from the SwiftUI environment rather than
//  constructing a `LanguageModelSession` themselves, so KueTests/UI previews can supply a
//  fixture-backed fake and never invoke a live model. KueApp installs the real,
//  `FoundationModels`-backed implementations at the root; nothing else needs to know they
//  exist.
//

import SwiftUI

private struct NLParserKey: EnvironmentKey {
    /// No-op default so a context that never sets this (a preview, an unrelated test) still
    /// compiles and safely reports "unavailable" rather than crashing on a missing model.
    static let defaultValue: NLParsing = UnavailableNLParser()
}

private struct AIAvailabilityCheckerKey: EnvironmentKey {
    static let defaultValue: AIAvailabilityChecking = UnavailableAIAvailabilityChecker()
}

extension EnvironmentValues {
    var nlParser: NLParsing {
        get { self[NLParserKey.self] }
        set { self[NLParserKey.self] = newValue }
    }

    var aiAvailabilityChecker: AIAvailabilityChecking {
        get { self[AIAvailabilityCheckerKey.self] }
        set { self[AIAvailabilityCheckerKey.self] = newValue }
    }
}

/// Default-value fallback — never reachable once KueApp installs the real checker, but keeps
/// `EnvironmentKey.defaultValue` honest instead of force-unwrapping something optional.
private struct UnavailableAIAvailabilityChecker: AIAvailabilityChecking {
    func currentAvailability() -> AIAvailabilityState { .deviceIneligible }
}

private struct UnavailableNLParser: NLParsing {
    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> {
        .failure(.modelUnavailable)
    }
}
