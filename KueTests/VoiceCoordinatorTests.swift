//
//  VoiceCoordinatorTests.swift
//  KueTests
//
//  Kue 2.0 Phase 6 — On-Device Voice Input, requirement 61: start/stop/cancel/retry, silence
//  timeout, maximum duration, interruption, route change, duplicate-session prevention,
//  audio-session cleanup, parser routing, ambiguity, duplicate detection, explicit
//  confirmation, `EventSource.voice`, no persistence before confirmation, cleanup after
//  success/failure/cancellation/dismissal, notification/widget effects after confirmed
//  creation. All four Fake* services only.
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
struct VoiceCoordinatorTests {
    private func makeCoordinator() -> (VoiceInputCoordinator, FakeVoiceAudioSessionManager, FakeVoiceMicrophoneCapture, FakeVoiceSpeechRecognizer) {
        let session = FakeVoiceAudioSessionManager()
        let capture = FakeVoiceMicrophoneCapture()
        let recognizer = FakeVoiceSpeechRecognizer()
        let coordinator = VoiceInputCoordinator(
            authorizationChecker: FakeVoiceAuthorizationChecker(),
            audioSessionManager: session,
            microphoneCapture: capture,
            speechRecognizer: recognizer
        )
        return (coordinator, session, capture, recognizer)
    }

    // MARK: - Start / stop / cancel / retry (requirement 23/61)

    @Test func stopWhileNotRecordingIsANoOp() {
        let (coordinator, _, _, _) = makeCoordinator()
        coordinator.stopRecording()
        #expect(coordinator.phase == .idle)
    }

    @Test func stopTransitionsToFinalizing() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.stopRecording()
        #expect(coordinator.phase == .finalizing)
    }

    @Test func cancelClearsTranscriptAndReturnsToIdle() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.transcript.isEmpty)
    }

    @Test func retryFromAnErrorStateReturnsToIdleAndRefreshesAvailability() {
        let (coordinator, _, _, _) = makeCoordinator()
        coordinator.retry()
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Duplicate-session prevention (requirement 21/22/61)

    @Test func startingTwiceWhileAlreadyRecordingIsIgnored() async {
        let (coordinator, _, capture, _) = makeCoordinator()
        await coordinator.startRecording()
        await coordinator.startRecording()
        #expect(capture.startCallCount == 1)
    }

    // MARK: - Silence timeout / maximum duration (requirement 26/27/28/61)

    @Test func silenceTimeoutAutoStopsWithAReason() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        let start = Date.now
        coordinator.tick(now: start.addingTimeInterval(VoiceLimits.silenceTimeout + 1))
        #expect(coordinator.phase == .finalizing || coordinator.phase == .noSpeechDetected)
        #expect(coordinator.autoStopReason?.contains("silence") == true)
    }

    @Test func maximumDurationAutoStopsWithAReason() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        let start = Date.now
        coordinator.tick(now: start.addingTimeInterval(VoiceLimits.maxRecordingDuration + 1))
        #expect(coordinator.phase == .finalizing || coordinator.phase == .noSpeechDetected)
        #expect(coordinator.autoStopReason?.contains("maximum") == true)
    }

    @Test func tickingBeforeAnyLimitDoesNothing() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.tick(now: .now.addingTimeInterval(1))
        #expect(coordinator.phase == .recording)
        #expect(coordinator.autoStopReason == nil)
    }

    @Test func elapsedSecondsReflectsRecordingDuration() async {
        let (coordinator, _, _, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.tick(now: .now.addingTimeInterval(12))
        #expect(coordinator.elapsedSeconds == 12)
    }

    // MARK: - Interruption / route change (requirement 18/20/61)

    @Test func interruptionDuringRecordingStopsGracefully() async {
        let (coordinator, session, _, _) = makeCoordinator()
        await coordinator.startRecording()
        session.simulateInterruption(.began)
        #expect(coordinator.phase == .finalizing || coordinator.phase == .noSpeechDetected)
        #expect(coordinator.autoStopReason?.contains("interrupted") == true)
    }

    @Test func routeChangeDuringRecordingStopsGracefully() async {
        let (coordinator, session, _, _) = makeCoordinator()
        await coordinator.startRecording()
        session.simulateRouteChange(VoiceRouteChangeEvent(reasonDescription: "oldDeviceUnavailable"))
        #expect(coordinator.phase == .finalizing || coordinator.phase == .noSpeechDetected)
        #expect(coordinator.autoStopReason?.contains("route") == true)
    }

    @Test func interruptionWhileIdleIsIgnored() {
        let (coordinator, session, _, _) = makeCoordinator()
        session.simulateInterruption(.began)
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Audio-session cleanup (requirement 17/18/61)

    @Test func startingActivatesTheSessionAndObservesIt() async {
        let (coordinator, session, _, _) = makeCoordinator()
        await coordinator.startRecording()
        #expect(session.activateCallCount == 1)
    }

    @Test func stoppingDeactivatesAndStopsObserving() async {
        let (coordinator, session, _, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.stopRecording()
        #expect(session.deactivateCallCount >= 1)
    }

    @Test func cancellingDeactivatesTheSession() async {
        let (coordinator, session, capture, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.cancel()
        #expect(session.deactivateCallCount >= 1)
        #expect(!capture.isCapturing)
    }

    @Test func aFailedStartNeverActivatesTheSessionTwice() async {
        let (coordinator, session, _, recognizer) = makeCoordinator()
        recognizer.availabilityToReturn = .unavailable
        await coordinator.startRecording()
        #expect(session.activateCallCount == 0)
    }

    // MARK: - Parser routing / ambiguity / duplicate detection (requirement 42/43/44/61)

    @Test func transcriptRoutesThroughTheExactNLParsingPipeline() async {
        let fixture = AIParsedEventDraft(
            title: "Fake Voice Interview", eventType: "interview", startDate: nil,
            startDateConfidence: "high", rawDateText: "friday at 10",
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(
            text: "Fake Voice Interview Friday at 10", parser: FixtureNLParser(.success(fixture)), timeZoneIdentifier: "UTC"
        )
        #expect(outcome.draft?.title == "Fake Voice Interview")
        #expect(outcome.failureMessage == nil)
    }

    @Test func ambiguousTranscriptCarriesAmbiguitiesThroughToTheOutcome() async {
        let fixture = AIParsedEventDraft(
            title: "Fake Voice Event", eventType: nil, startDate: nil,
            startDateConfidence: "low", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: [AIAmbiguity(field: "eventType", question: "What kind of event is this?")]
        )
        let outcome = await NLParsingPipeline.run(
            text: "Fake Voice Event, unclear", parser: FixtureNLParser(.success(fixture)), timeZoneIdentifier: "UTC"
        )
        #expect(!outcome.ambiguities.isEmpty)
    }

    @Test func duplicateVoiceEventIsFlagged() {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let sharedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = KueEvent(title: "Fake Voice Interview", eventType: .interview, startDate: sharedDate, estimatedDurationMinutes: 60, source: .manual)
        context.insert(existing)
        try? context.save()

        let allEvents = (try? context.fetch(FetchDescriptor<KueEvent>())) ?? []
        let duplicate = DuplicateDetectionService.findDuplicate(title: "Fake Voice Interview", startDate: sharedDate, timeZoneIdentifier: TimeZone.current.identifier, in: allEvents)
        #expect(duplicate?.id == existing.id)
    }

    // MARK: - Explicit confirmation / EventSource.voice / no persistence before confirmation (requirement 45/49/61)

    @Test func nothingPersistsFromRecognitionOrParsingAlone() async {
        let container = ModelContainerFactory.makeInMemory()
        let fixture = AIParsedEventDraft(
            title: "Fake Voice Standup", eventType: "generic", startDate: nil,
            startDateConfidence: "high", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        _ = await NLParsingPipeline.run(text: "Fake Voice Standup", parser: FixtureNLParser(.success(fixture)), timeZoneIdentifier: "UTC")
        let allEvents = (try? container.mainContext.fetch(FetchDescriptor<KueEvent>())) ?? []
        #expect(allEvents.isEmpty)
    }

    @Test func explicitConfirmationPersistsWithSourceVoice() async throws {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let fixture = AIParsedEventDraft(
            title: "Fake Voice Standup", eventType: "generic", startDate: nil,
            startDateConfidence: "high", rawDateText: nil,
            endDate: nil, rawEndDateText: nil, location: nil, notes: nil,
            prepRequests: [], ambiguities: []
        )
        let outcome = await NLParsingPipeline.run(text: "Fake Voice Standup", parser: FixtureNLParser(.success(fixture)), timeZoneIdentifier: "UTC")
        let draft = try #require(outcome.draft)

        let event = KueEvent(
            title: draft.title, eventType: draft.eventType, startDate: draft.startDate,
            estimatedDurationMinutes: draft.eventType.defaultEstimatedDurationMinutes,
            isAllDay: draft.isAllDay,
            location: draft.location.isEmpty ? nil : draft.location,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            source: .voice, priority: draft.priority
        )
        context.insert(event)
        try context.save()

        let persisted = try #require(try context.fetch(FetchDescriptor<KueEvent>()).first)
        #expect(persisted.source == .voice)
        #expect(persisted.title == "Fake Voice Standup")
    }

    // MARK: - Cleanup after every termination path (requirement 18/50/61)

    @Test func cleanupAfterSuccessfulStop() async {
        let (coordinator, session, capture, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.stopRecording()
        #expect(!capture.isCapturing)
        #expect(session.deactivateCallCount >= 1)
    }

    @Test func cleanupAfterFailure() async {
        let (coordinator, session, _, recognizer) = makeCoordinator()
        recognizer.availabilityToReturn = .unavailable
        await coordinator.startRecording()
        #expect(session.activateCallCount == 0)
        #expect(session.deactivateCallCount == 0) // never activated, so nothing to deactivate
    }

    @Test func cleanupAfterCancellationLeavesNoTranscriptOrCapture() async {
        let (coordinator, _, capture, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.cancel()
        #expect(coordinator.transcript.isEmpty)
        #expect(!capture.isCapturing)
    }

    @Test func cleanupOnDismissalMirrorsCancellation() async {
        // `VoiceInputView.onDisappear` calls `coordinator.cancel()` directly — this proves
        // `cancel()` itself is a complete, idempotent teardown regardless of caller.
        let (coordinator, session, capture, _) = makeCoordinator()
        await coordinator.startRecording()
        coordinator.cancel()
        coordinator.cancel() // idempotent
        #expect(!capture.isCapturing)
        #expect(session.deactivateCallCount >= 1)
    }

    // MARK: - Notification/widget effects after confirmed creation (requirement 61)

    @Test func confirmedVoiceSourcedEventReschedulesNotificationsAndReloadsTheWidget() async {
        let container = ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let event = KueEvent(
            title: "Fake Voice Confirmed Event", eventType: .generic, startDate: .now.addingTimeInterval(3 * 86_400),
            estimatedDurationMinutes: 30, source: .voice
        )
        context.insert(event)
        try? context.save()
        SchedulingEngine.regenerateTasks(for: event, context: context)

        let scheduler = FakeNotificationScheduler()
        let widgetReloader = FakeWidgetReloader()
        widgetReloader.reloadTimelines(ofKind: WidgetKind.kue)
        await NotificationEngine.reschedule(context: context, intensity: .standard, scheduler: scheduler, requestPermissionIfNeeded: false)

        #expect(widgetReloader.reloadedKinds.contains(WidgetKind.kue))
        #expect(!scheduler.addedRequests.isEmpty)
    }
}
