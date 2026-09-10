//
//  MacCalendarImportListView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 cleanup — native Mac "Import from Calendar" sheet. Mirrors
//  Kue/Features/CalendarImport/CalendarImportListView.swift's own authorization-state handling
//  and recurrence-choice flow exactly (same states, same `CalendarImportPipeline.draft`) — no
//  re-derived policy — but hands the resulting `EventDraft` to `MacEventEditorView` (via
//  `.addFromDraft`) for draft review/edit/save instead of iOS's `EventFormView`. See docs/29
//  "H." Reads through whatever `calendarProvider` `KueMacApp` installed —
//  `FakeCalendarProvider` under automation/tests, `SystemCalendarProvider` otherwise; never
//  reaches for `SystemCalendarProvider`/`EKEventStore` directly.
//

import SwiftUI

struct MacCalendarImportListView: View {
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
                    messageState("Calendar access is off. Turn it on in System Settings to import events.", systemImage: "calendar.badge.exclamationmark")
                case .restricted:
                    messageState("Calendar access is restricted on this Mac.", systemImage: "lock")
                case .unavailable, .unknown:
                    messageState("Calendar access isn't available on this Mac.", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .navigationTitle("Import from Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelCalendarImportButton")
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
                    Text("Kue can't fully represent this event's repeat pattern — only importing this single occurrence is available.")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var eventList: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No Upcoming Calendar Events", systemImage: "calendar", description: Text("Nothing found in the next 90 days."))
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
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calendarImportRow-\(event.externalIdentifier)")
                }
                .accessibilityIdentifier("calendarImportList")
            }
        }
    }

    private var requestAccessState: some View {
        VStack(spacing: 16) {
            // Contextual permission education, shown right here — only after the user
            // deliberately opened this sheet — matching CalendarImportListView's own rule.
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
            .disabled(isRequestingAccess)
        }
        .padding()
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
        // Caller (`RootSplitView`) dismisses this sheet first, then presents the review editor
        // on top — the same proven sequencing `CalendarImportListView`'s own header documents,
        // avoiding a nested-sheet presentation race.
        onSelect(outcome.draft)
    }
}

// Kue 3.0 Phase 1 cleanup — always the fake provider in previews, never `SystemCalendarProvider`
// — Xcode's preview canvas must never touch the real Calendar database.
#Preview("Calendar Import — Mac") {
    MacCalendarImportListView { _ in }
        .environment(\.calendarProvider, FakeCalendarProvider.makeUITestFixture())
}
