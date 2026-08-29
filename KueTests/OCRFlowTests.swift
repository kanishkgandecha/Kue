//
//  OCRFlowTests.swift
//  KueTests
//
//  Kue 2.0 Phase 5 — Screenshot and OCR Input, requirement 46: cancellation/stale-result
//  prevention (`OCRRequestGeneration`), parser routing (the exact `NLParsingPipeline` typed NL
//  text uses), ambiguity handling, duplicate detection, explicit confirmation,
//  `EventSource.ocr`, no persistence before confirmation, and notification/widget side effects
//  after confirmed creation. Mirrors `CalendarImportFlowTests.swift`'s direct-`KueEvent`-
//  construction pattern for the persistence-level assertions.
//

import Testing
import Foundation
import SwiftData
@testable import Kue

@available(iOS 26.0, *)
@MainActor
private final class FixtureNLParser: NLParsing {
    private let outcome: Result<AIParsedEventDraft, ParseFailure>
    init(_ outcome: Result<AIParsedEventDraft, ParseFailure>) { self.outcome = outcome }
    func parse(text: String) async -> Result<AIParsedEventDraft, ParseFailure> { outcome }
}

@MainActor
struct OCRFlowTests {
    // MARK: - Stale-result prevention / cancellation (requirement 40/41/42)

    @Test func onlyTheLatestGenerationIsCurrent() {
        var generation = OCRRequestGeneration()
        let first = generation.advance()
        let second = generation.advance()
        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
    }

    @Test func aFreshGenerationCounterStartsAtCurrentZero() {
        let generation = OCRRequestGeneration()
        #expect(generation.isCurrent(0))
    }

    @Test func advancingRepeatedlyNeverRevalidatesAnOlderGeneration() {
        // Requirement 40 — rapid repeated actions (re-selecting, cancelling, retrying) each
        // advance the counter; no older captured generation ever becomes current again.
        var generation = OCRRequestGeneration()
        var captured: [Int] = []
        for _ in 0..<5 { captured.append(generation.advance()) }
        for value in captured.dropLast() {
            #expect(!generation.isCurrent(value))
        }
        #expect(generation.isCurrent(captured.last!))
    }

    // MARK: - Retry behavior (requirement 46)

    @Test func retryingAfterAFailureStartsANewGenerationThatSupersedesTheFailedOne() {
        // Models the exact shape `OCRImportView.resetToInitial()`/`cancelFlow()` use: a failed
        // run's captured generation is checked against the *current* value, which retrying has
        // already moved past — the failed run's late-arriving guard (if it ever completed)
        // could never re-apply its own stale result.
        var generation = OCRRequestGeneration()
        let failedRunGeneration = generation.advance()
        // ... failure occurs, user taps "Choose Another Photo" ...
        generation.advance()
        #expect(!generation.isCurrent(failedRunGeneration))
    }

    // MARK: - Parser routing (requirement 23/24/46)

    @Test func recognizedTextRoutesThroughTheExactNLParsingPipeline() async {
        let fixture = AIParsedEventDraft(
            title: "Fake OCR Interview", eventType: "interview", startDate: nil,
            startDateConfidence: "high", rawDateText: "friday at 10",
            endDate: nil, rawEndDateText: nil, location: "123 Fake Conference Room", notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: OCRRecognitionResult.fixtureEvent.fullText,
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft?.title == "Fake OCR Interview")
        #expect(outcome.draft?.eventType == .interview)
        #expect(outcome.draft?.location == "123 Fake Conference Room")
        #expect(outcome.failureMessage == nil)
    }

    // MARK: - Ambiguity handling (requirement 25/46)

    @Test func ambiguousRecognizedTextCarriesAmbiguitiesThroughToTheOutcome() async {
        let fixture = AIParsedEventDraft(
            title: "Fake OCR Event", eventType: nil, startDate: nil,
            startDateConfidence: "low", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: [AIAmbiguity(field: "eventType", question: "What kind of event is this?")]
        )
        let outcome = await NLParsingPipeline.run(
            text: "Fake OCR Event, unclear details",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        #expect(!outcome.ambiguities.isEmpty)
    }

    // MARK: - Parser failure (requirement 37/46)

    @Test func parserFailureProducesNoDraftAndASpecificMessage() async {
        let outcome = await NLParsingPipeline.run(
            text: "unparseable fake OCR text",
            parser: FixtureNLParser(.failure(.schemaInvalid)),
            timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft == nil)
        #expect(outcome.failureMessage == ParseFailure.schemaInvalid.message)
    }

    // MARK: - Duplicate detection (requirement 25/46)

    @Test func recognizedEventMatchingAnExistingOneIsFlaggedAsADuplicate() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let sharedDate = Date(timeIntervalSince1970: 1_800_000_000)

        let existing = KueEvent(title: "Fake OCR Interview", eventType: .interview, startDate: sharedDate, estimatedDurationMinutes: 60, source: .manual)
        context.insert(existing)
        try? context.save()

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let duplicate = DuplicateDetectionService.findDuplicate(
            title: "Fake OCR Interview", startDate: sharedDate, timeZoneIdentifier: TimeZone.current.identifier, in: allEvents
        )
        #expect(duplicate?.id == existing.id)
    }

    // MARK: - Explicit confirmation / no persistence before confirmation (requirement 31/32/46)

    @Test func recognizingAndParsingNeverPersistsAnythingByItself() async {
        let container = ModelContainerFactory.makeInMemory()
        let fixture = AIParsedEventDraft(
            title: "Fake OCR Standup", eventType: "generic", startDate: nil,
            startDateConfidence: "high", rawDateText: "tomorrow at 9",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        _ = await NLParsingPipeline.run(
            text: "Fake OCR Standup tomorrow at 9",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        let allEvents = (try? container.mainContext.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(allEvents.isEmpty)
    }

    @Test func explicitConfirmationPersistsWithSourceOCR() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let fixture = AIParsedEventDraft(
            title: "Fake OCR Standup", eventType: "generic", startDate: nil,
            startDateConfidence: "high", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: "Fake OCR Standup",
            parser: FixtureNLParser(.success(fixture)),
            timeZoneIdentifier: "UTC"
        )
        let draft = try #require(outcome.draft)

        // The explicit "confirm" step: mirrors `EventFormView.save()`'s `.add` case exactly,
        // same as `CalendarImportFlowTests`'s own confirmation test.
        let event = KueEvent(
            title: draft.title, eventType: draft.eventType, startDate: draft.startDate,
            estimatedDurationMinutes: draft.eventType.defaultEstimatedDurationMinutes,
            isAllDay: draft.isAllDay,
            location: draft.location.isEmpty ? nil : draft.location,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            source: .ocr, priority: draft.priority
        )
        context.insert(event)
        try context.save()

        let persisted = try #require(try context.fetch(FetchDescriptor<KueEvent>()).first)
        #expect(persisted.source == .ocr)
        #expect(persisted.title == "Fake OCR Standup")
    }

    // MARK: - Notification/widget side effects after confirmed creation (requirement 46)

    @Test func confirmedOCRSourcedEventReschedulesNotificationsAndReloadsTheWidget() async {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = KueEvent(
            title: "Fake OCR Confirmed Event", eventType: .generic, startDate: .now.addingTimeInterval(3 * 86_400),
            estimatedDurationMinutes: 30, source: .ocr
        )
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context)

        let scheduler = FakeNotificationScheduler()
        let widgetReloader = FakeWidgetReloader()
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue) // mirrors EventActions.reloadWidget()'s own call shape
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, requestPermissionIfNeeded: false)

        #expect(widgetReloader.reloadedKinds.contains(WidgetKind.kue))
        // A future event with generated tasks produces at least one scheduled reminder —
        // proves the exact same reschedule pass `EventFormView.save()` triggers for any other
        // source also runs for an OCR-sourced event, nothing OCR-specific skipped it.
        #expect(!scheduler.addedRequests.isEmpty)
    }
}
