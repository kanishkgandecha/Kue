//
//  NLDraftNormalizerTests.swift
//  KueTests
//
//  See docs/10-testing-strategy.md "AI tests (fixture-based, not live-model)". Fixtures here
//  are hand-built `AIParsedEventDraft` values (as if a live model had already produced
//  them) fed straight into the real, deterministic `NLDraftNormalizer` — no
//  `LanguageModelSession` anywhere in this file. Tagged with `nlParserPromptVersion`
//  (docs/06-ai-layer.md "Prompt versioning") so a prompt change is a visible reminder to
//  re-check this file.
//

import Testing
import Foundation
@testable import Kue

struct NLDraftNormalizerTests {
    /// Fixtures below were written against this prompt version — see
    /// docs/06-ai-layer.md "Prompt versioning".
    private static let fixturePromptVersion = nlParserPromptVersion

    /// Monday, June 2 2025, 09:00 America/New_York — same anchor as RelativeDateResolverTests.
    private static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(year: 2025, month: 6, day: 2, hour: 9))!
    }()
    private static let timeZoneIdentifier = "America/New_York"

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func draft(
        title: String,
        eventType: String? = "generic",
        startDate: String? = nil,
        rawDateText: String? = nil,
        endDate: String? = nil,
        rawEndDateText: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        prepRequests: [AIPrepRequest] = [],
        ambiguities: [AIAmbiguity] = []
    ) -> AIParsedEventDraft {
        AIParsedEventDraft(
            title: title,
            eventType: eventType,
            startDate: startDate,
            startDateConfidence: rawDateText == nil && startDate != nil ? "high" : "low",
            rawDateText: rawDateText,
            endDate: endDate,
            rawEndDateText: rawEndDateText,
            location: location,
            notes: notes,
            prepRequests: prepRequests,
            ambiguities: ambiguities
        )
    }

    private func normalize(_ parsed: AIParsedEventDraft) -> NLDraftNormalizer.Result {
        NLDraftNormalizer.normalize(parsed, referenceDate: Self.referenceDate, timeZoneIdentifier: Self.timeZoneIdentifier)
    }

    // MARK: - Valid, unambiguous, across event types

    @Test(arguments: EventType.allCases)
    func validUnambiguousInputNormalizesCleanlyForEveryType(eventType: EventType) {
        let parsed = draft(
            title: "Team sync",
            eventType: eventType.rawValue,
            rawDateText: "tomorrow at 10",
            rawEndDateText: eventType == .trip ? "for 3 days" : nil
        )
        let result = normalize(parsed)
        #expect(result.ambiguities.isEmpty)
        #expect(result.draft.title == "Team sync")
        #expect(result.draft.eventType == eventType)
        #expect(result.draft.startDate == Self.day(2025, 6, 3, hour: 10))
        if eventType == .trip {
            #expect(result.draft.endDate == Self.day(2025, 6, 6, hour: 10))
        }
    }

    // MARK: - Missing (schema-legal, but nothing to resolve)

    @Test func missingDateLanguageIsAnAmbiguityNotAGuess() {
        let parsed = draft(title: "Something", startDate: nil, rawDateText: nil)
        let result = normalize(parsed)
        #expect(result.ambiguities.contains { $0.field == "startDate" })
    }

    @Test func missingOrUnrecognizedEventTypeFallsBackToGeneric() {
        let parsed = draft(title: "Something", eventType: nil, rawDateText: "today")
        #expect(normalize(parsed).draft.eventType == .generic)

        let parsedUnrecognized = draft(title: "Something", eventType: "not-a-real-type", rawDateText: "today")
        #expect(normalize(parsedUnrecognized).draft.eventType == .generic)
    }

    // MARK: - Malformed (unresolvable raw text, not silently defaulted)

    @Test func unresolvableRawDateTextIsAnAmbiguity() {
        let parsed = draft(title: "Something", rawDateText: "sometime soonish")
        let result = normalize(parsed)
        #expect(result.ambiguities.contains { $0.field == "startDate" })
    }

    // MARK: - Ambiguous (model-flagged, e.g. unclear event type)

    @Test func modelFlaggedAmbiguityIsCarriedThrough() {
        let parsed = draft(
            title: "Board thing",
            eventType: nil,
            rawDateText: "next friday",
            ambiguities: [AIAmbiguity(field: "eventType", question: "Is this an interview or a generic meeting?")]
        )
        let result = normalize(parsed)
        #expect(result.ambiguities.contains { $0.field == "eventType" && $0.question.contains("interview") })
    }

    // MARK: - Trip range (rawEndDateText required for .trip)

    @Test func tripFromNextFridayUntilSundayResolvesConcreteEndDate() {
        let parsed = draft(
            title: "Trip to Boston",
            eventType: "trip",
            rawDateText: "next friday",
            rawEndDateText: "until sunday"
        )
        let result = normalize(parsed)
        #expect(result.ambiguities.isEmpty)
        #expect(result.draft.startDate == Self.day(2025, 6, 6))
        #expect(result.draft.endDate == Self.day(2025, 6, 8))
    }

    @Test func tripWithoutRawEndDateTextIsARequiredFieldAmbiguityNotAGuessedDuration() {
        let parsed = draft(title: "Trip to Boston", eventType: "trip", rawDateText: "next friday", rawEndDateText: nil)
        let result = normalize(parsed)
        #expect(result.ambiguities.contains { $0.field == "endDate" })
    }

    // MARK: - Range sanity (~2 years)

    @Test func dateFarInTheFutureIsFlaggedNotSilentlyClamped() {
        // ~3.8 years out from the reference date.
        let parsed = draft(title: "Something", rawDateText: "in 200 weeks")
        let result = normalize(parsed)
        #expect(result.ambiguities.contains { $0.field == "startDate" })
    }

    // MARK: - Timezone (requirement 7 — resolution pinned to the event's timezone)

    @Test func relativeDateResolvesAgainstThePinnedTimezoneNotUTC() {
        let tokyoReference = Self.referenceDate // 09:00 America/New_York = an instant
        let result = NLDraftNormalizer.normalize(
            draft(title: "Something", rawDateText: "tomorrow"),
            referenceDate: tokyoReference,
            timeZoneIdentifier: "Asia/Tokyo"
        )
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let expected = tokyoCalendar.date(byAdding: .day, value: 1, to: tokyoCalendar.startOfDay(for: tokyoReference))
        #expect(result.draft.startDate == expected)
        #expect(result.draft.timeZoneIdentifier == "Asia/Tokyo")
    }
}
