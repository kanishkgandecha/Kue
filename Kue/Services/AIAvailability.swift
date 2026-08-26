//
//  AIAvailability.swift
//  Kue
//
//  See docs/06-ai-layer.md "Runtime availability" — four distinct states, each with its own
//  required message, checked once per app session (not per keystroke) and used to gate
//  whether the Add screen's NL entry point is shown/enabled at all.
//

import Foundation
import FoundationModels

enum AIAvailabilityState: Equatable {
    case available
    case deviceIneligible
    case appleIntelligenceDisabled
    case modelNotReady

    var isAvailable: Bool { self == .available }

    /// Exact copy from docs/06-ai-layer.md's "V1 message" column. `nil` for `.available` —
    /// there's nothing to show when parsing just works.
    var message: String? {
        switch self {
        case .available:
            return nil
        case .deviceIneligible:
            return "AI text parsing isn't available on this device — add it manually instead"
        case .appleIntelligenceDisabled:
            return "Turn on Apple Intelligence in Settings to use AI parsing — or add this manually"
        case .modelNotReady:
            return "AI parsing is still getting ready on this device — add this manually for now"
        }
    }
}

/// Dependency-injection seam (requirement 10) — tests supply a fake that never touches the
/// real framework, so a fixture run is deterministic and doesn't depend on the test host's
/// actual Apple Intelligence state.
@MainActor
protocol AIAvailabilityChecking {
    func currentAvailability() -> AIAvailabilityState
}

/// Caches after the first call — "once per app session," per docs/06-ai-layer.md — since
/// `SystemLanguageModel.default.availability` is itself a live re-check on every access.
@available(iOS 26.0, *)
@MainActor
final class SystemAIAvailabilityChecker: AIAvailabilityChecking {
    private var cached: AIAvailabilityState?

    func currentAvailability() -> AIAvailabilityState {
        if let cached { return cached }
        let resolved = Self.map(SystemLanguageModel.default.availability)
        cached = resolved
        return resolved
    }

    private static func map(_ availability: SystemLanguageModel.Availability) -> AIAvailabilityState {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceIneligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceDisabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .deviceIneligible
            }
        }
    }
}
