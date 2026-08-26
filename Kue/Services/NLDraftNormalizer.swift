//
//  NLDraftNormalizer.swift
//  Kue
//
//  See docs/06-ai-layer.md "Validation & normalization (deterministic, non-AI code)" —
//  steps 2-4 (date resolution, range sanity, event-type fallback). Step 1 (schema check) is
//  enforced upstream by `@Generable`'s guided generation (see AIParsedEventDraft) plus
//  EventValidator once this normalizer's output lands in the reused EventFormView; step 5
//  (duplicate check) is likewise already handled by EventFormView.checkDuplicate() against
//  the same DuplicateDetectionService every manual entry uses — no need to duplicate it here.
//
//  Pure, synchronous, `@testable`-only Foundation — no AI, no FoundationModels import. This
//  is "AI interprets, [Kue's own code] decides" (AGENTS.md) for the parser path specifically.
//

import Foundation

/// One ambiguity banner, adjacent to the field it concerns (docs/09-screens-and-ux.md
/// "Confirmation / ambiguity UI"). `field` is free text from the model (or one of this
/// normalizer's own field names below) — EventFormView maps recognized names to a specific
/// section and falls back to a general banner for anything else.
struct DraftAmbiguity: Identifiable, Equatable {
    var field: String
    var question: String
    var id: String { field + "|" + question }
}

enum NLDraftNormalizer {
    struct Result {
        var draft: EventDraft
        /// Non-empty means "Create" must stay disabled until each is resolved — requirement 8.
        var ambiguities: [DraftAmbiguity]
    }

    /// `referenceDate`/`timeZoneIdentifier` pin relative-date resolution to the event's own
    /// timezone (requirement 7), not necessarily the device's live one.
    @available(iOS 26.0, *)
    static func normalize(
        _ parsed: AIParsedEventDraft,
        referenceDate: Date,
        timeZoneIdentifier: String
    ) -> Result {
        var ambiguities: [DraftAmbiguity] = []
        var draft = EventDraft()
        draft.title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.timeZoneIdentifier = timeZoneIdentifier

        // Step 4: eventType fallback — null or unrecognized normalizes to .generic, never
        // left null in the draft.
        let eventType = parsed.eventType.flatMap { EventType(rawValue: $0) } ?? .generic
        draft.eventType = eventType

        // Step 2/3: rawDateText always wins over the model's own startDate guess — resolved
        // deterministically, then range-checked.
        let resolvedStart = resolveStart(parsed: parsed, referenceDate: referenceDate, timeZoneIdentifier: timeZoneIdentifier)
        switch resolvedStart {
        case .resolved(let resolved) where isWithinSaneRange(resolved.date, of: referenceDate):
            draft.startDate = resolved.date
            draft.isAllDay = !resolved.hasTimeComponent
        case .resolved(let resolved):
            // Step 3: range sanity — flag, don't silently clamp.
            draft.startDate = resolved.date
            ambiguities.append(DraftAmbiguity(
                field: "startDate",
                question: "\(resolved.date.formatted(date: .abbreviated, time: .omitted)) is far from today — is that right?"
            ))
        case .unresolved(let raw):
            ambiguities.append(DraftAmbiguity(
                field: "startDate",
                question: raw.map { "Couldn't figure out a date from \"\($0)\" — what date did you mean?" }
                    ?? "What date is this?"
            ))
        }

        // .trip requires an end date — unresolved is a required-field ambiguity, not a
        // guessed duration.
        if eventType == .trip {
            if let startDate = resolvedStart.date,
               let resolvedEnd = resolveEnd(parsed: parsed, startDate: startDate, timeZoneIdentifier: timeZoneIdentifier) {
                draft.endDate = resolvedEnd
            } else {
                ambiguities.append(DraftAmbiguity(field: "endDate", question: "When does the trip end?"))
            }
        }

        if let location = parsed.location, !location.isEmpty { draft.location = location }
        if let notes = parsed.notes, !notes.isEmpty { draft.notes = notes }

        for modelAmbiguity in parsed.ambiguities {
            ambiguities.append(DraftAmbiguity(field: modelAmbiguity.field, question: modelAmbiguity.question))
        }

        return Result(draft: draft, ambiguities: ambiguities)
    }

    // MARK: - Date resolution (step 2)

    private enum StartResolution {
        case resolved(ResolvedDate)
        case unresolved(rawText: String?)

        var date: Date? {
            if case .resolved(let resolved) = self { return resolved.date }
            return nil
        }
    }

    @available(iOS 26.0, *)
    private static func resolveStart(
        parsed: AIParsedEventDraft,
        referenceDate: Date,
        timeZoneIdentifier: String
    ) -> StartResolution {
        if let rawDateText = parsed.rawDateText, !rawDateText.isEmpty {
            if let resolved = RelativeDateResolver.resolve(
                text: rawDateText, referenceDate: referenceDate, timeZoneIdentifier: timeZoneIdentifier
            ) {
                return .resolved(resolved)
            }
            return .unresolved(rawText: rawDateText)
        }
        // No rawDateText at all — the rare case the model asserted an absolute date directly.
        if let iso = parsed.startDate, let date = ISO8601DateFormatter().date(from: iso) {
            return .resolved(ResolvedDate(date: date, hasTimeComponent: true))
        }
        return .unresolved(rawText: nil)
    }

    @available(iOS 26.0, *)
    private static func resolveEnd(
        parsed: AIParsedEventDraft,
        startDate: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        if let rawEndDateText = parsed.rawEndDateText, !rawEndDateText.isEmpty,
           let resolved = RelativeDateResolver.resolveEndDate(
               text: rawEndDateText, startDate: startDate, timeZoneIdentifier: timeZoneIdentifier
           ) {
            return resolved
        }
        if let iso = parsed.endDate, let date = ISO8601DateFormatter().date(from: iso) {
            return date
        }
        return nil
    }

    private static func isWithinSaneRange(_ date: Date, of referenceDate: Date) -> Bool {
        let twoYears: TimeInterval = 2 * 365 * 24 * 60 * 60
        return abs(date.timeIntervalSince(referenceDate)) <= twoYears
    }
}
