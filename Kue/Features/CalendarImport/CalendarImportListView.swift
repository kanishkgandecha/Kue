//
//  CalendarImportListView.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. Requirement 7/8/9: "Import from Calendar" in
//  the Add flow — an event-selection UI appropriate to the current authorization level, that
//  hands the caller back a fully built, still-editable `EventDraft` (requirement 12/13: never
//  auto-creates a `KueEvent` itself). See docs/18-calendar-integration.md "Import UI".
//

import SwiftUI

struct CalendarImportListView: View {
    /// Presenter (`HomeView`) opens `EventFormView(prefilledDraft:...)` itself, after this
    /// sheet has fully dismissed — the same "dismiss, then present on top of Home" sequencing
    /// `TemplatesView`'s own completion already uses, avoiding the nested-sheet bug documented
    /// there (TemplateAndScheduleUITests.swift's own header).
    var onSelect: (EventDraft) -> Void

    @Environment(\.calendarProvider) private var calendarProvider
    @Environment(\.dismiss) private var dismiss

    @State private var authorizationState: CalendarAuthorizationState = .notDetermined
    @State private var isRequestingAccess = false
    @State private var events: [KueCalendarEvent] = []
    @State private var recurrenceChoiceTarget: KueCalendarEvent?

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationState {
                case .fullAccess:
                    eventList
                case .notDetermined:
                    requestAccessState
                case .writeOnly:
                    messageState(
                        "Kue can add events to Calendar, but needs full access to read and import existing events.",
                        systemImage: "calendar.badge.plus"
                    )
                case .denied:
                    messageState("Calendar access is off. Turn it on in Settings to import events.", systemImage: "calendar.badge.exclamationmark")
                case .restricted:
                    messageState("Calendar access is restricted on this device.", systemImage: "lock")
                case .unavailable, .unknown:
                    messageState("Calendar access isn't available on this device.", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .navigationTitle("Import from Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                authorizationState = calendarProvider.authorizationState()
                refreshEvents()
            }
            .confirmationDialog(
                "This event repeats. Import just this occurrence, or as a repeating Kue event?",
                isPresented: Binding(get: { recurrenceChoiceTarget != nil }, set: { if !$0 { recurrenceChoiceTarget = nil } }),
                titleVisibility: .visible
            ) {
                if let target = recurrenceChoiceTarget {
                    Button("Import This Occurrence Only") {
                        select(target, choice: .singleOccurrenceOnly)
                    }
                    .accessibilityIdentifier("importSingleOccurrenceButton")

                    if target.recurrence?.isFullySupported == true {
                        Button("Import as Repeating Kue Event") {
                            select(target, choice: .convertToSeries)
                        }
                        .accessibilityIdentifier("importAsSeriesButton")
                    }
                }
            } message: {
                if recurrenceChoiceTarget?.recurrence?.isFullySupported == false {
                    // Requirement 37 — the limitation is stated up front, before the choice is
                    // even made, not discovered only after importing.
                    Text("Kue can't fully represent this event's repeat pattern — only importing this single occurrence is available.")
                }
            }
        }
    }

    private var eventList: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(
                    "No Upcoming Calendar Events",
                    systemImage: "calendar",
                    description: Text("Nothing found in the next 90 days.")
                )
            } else {
                List(events, id: \.externalIdentifier) { event in
                    Button {
                        if event.recurrence != nil {
                            recurrenceChoiceTarget = event
                        } else {
                            select(event, choice: .singleOccurrenceOnly)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                            Text(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("calendarImportRow-\(event.externalIdentifier)")
                }
                .accessibilityIdentifier("calendarImportList")
            }
        }
    }

    private var requestAccessState: some View {
        VStack(spacing: 16) {
            // Requirement 5: contextual permission education, shown right here — only after
            // the user deliberately tapped "Import from Calendar" — never at launch/onboarding.
            Text(CalendarAuthorizationState.notDetermined.explanation ?? "")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button {
                Task { await requestAccess() }
            } label: {
                if isRequestingAccess {
                    ProgressView()
                } else {
                    Text("Allow Calendar Access")
                }
            }
            .accessibilityIdentifier("importRequestAccessButton")
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingAccess)
        }
        .padding()
        // Deliberately no identifier on this outer container: SwiftUI can propagate a
        // container-level `.accessibilityIdentifier` down onto a child that already has its
        // own (observed directly in a UI-test accessibility-tree dump — both this container
        // and the button below reported the *container's* identifier), so
        // `importRequestAccessButton` on the button alone is what a test should match against;
        // its presence already proves this exact state is showing.
    }

    private func messageState(_ message: String, systemImage: String) -> some View {
        ContentUnavailableView(message, systemImage: systemImage)
            .accessibilityIdentifier("calendarImportUnavailableState")
    }

    private func requestAccess() async {
        isRequestingAccess = true
        authorizationState = await calendarProvider.requestAccess()
        isRequestingAccess = false
        refreshEvents()
    }

    private func refreshEvents() {
        guard authorizationState.canReadEvents else { events = []; return }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        let end = calendar.date(byAdding: .day, value: 90, to: .now) ?? .now
        events = calendarProvider.fetchEvents(from: start, to: end).sorted { $0.startDate < $1.startDate }
    }

    private func select(_ event: KueCalendarEvent, choice: CalendarImportRecurrenceChoice) {
        recurrenceChoiceTarget = nil
        let outcome = CalendarImportPipeline.draft(from: event, recurrenceChoice: choice)
        // The caller (`HomeView`) flips its own `isImportingFromCalendar` off in response,
        // rather than this view calling `dismiss()` on itself — same proven sequencing
        // `TemplatesView`'s own completion closure uses (see `HomeView.body`'s own comment),
        // which is what actually lets the *next* sheet (the prefilled `EventFormView`) present
        // reliably right after this one closes.
        onSelect(outcome.draft)
    }
}
