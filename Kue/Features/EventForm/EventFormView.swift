//
//  EventFormView.swift
//  Kue
//
//  See docs/09-screens-and-ux.md "Add" / "Confirmation / ambiguity UI" / "Widget
//  configuration" and docs/04-event-types.md "Per-type fields". One form serves three roles:
//  manual entry (manual entry *is* the confirmation — "Manual entry skips this screen
//  entirely"), and, in `.add` mode, also the NL input surface *and* the post-parse
//  confirmation sheet — docs/09 calls for "one sheet ... same field layout as manual entry,
//  but pre-filled," which this satisfies by re-populating this same form's fields in place
//  rather than presenting a second sheet on top.
//

import SwiftUI
import SwiftData

struct EventFormView: View {
    enum Mode {
        /// `initialEventType` lets the Templates screen (Phase 6) pre-select a type without
        /// its own copy of the form — still just manual entry underneath, zero AI involved.
        case add(initialEventType: EventType)
        case edit(KueEvent)
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nlParser) private var nlParser
    @Environment(\.aiAvailabilityChecker) private var aiAvailabilityChecker
    // Kue 2.0 Phase 7 — requirement 32/34: a successful create/save gets one restrained
    // confirmation haptic; never the real Taptic Engine under `KueUITests`.
    @Environment(\.kueHaptics) private var haptics
    @Query private var allEvents: [KueEvent]

    @State private var draft: EventDraft
    @State private var draftSource: EventSource = .manual
    @State private var errors: [EventValidationError] = []
    @State private var recurrenceErrors: [RecurrenceValidationError] = []
    @State private var duplicate: KueEvent?
    @State private var isViewingDuplicate = false
    /// Kue 2.0 Phase 3 — only meaningful when editing an occurrence that already belongs to a
    /// series (`event.seriesID != nil`); see docs/17-recurring-events.md "Editing scope."
    @State private var editScope: RecurrenceEditScope = .thisOccurrence

    // MARK: NL parsing state (requirements 5-9) — `.add` mode only.
    @State private var nlText = ""
    @State private var isParsing = false
    @State private var ambiguities: [DraftAmbiguity] = []
    @State private var parseFailureMessage: String?
    @State private var availability: AIAvailabilityState = .deviceIneligible
    /// docs/03-data-model.md `UserPreference.aiParsingEnabled`: "User can force manual-only
    /// entry." Distinct from `availability` — this is a user choice, not a hardware/OS state.
    @State private var isAIParsingEnabled = true

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add(let initialEventType):
            _draft = State(initialValue: EventDraft(eventType: initialEventType))
        case .edit(let event):
            var initialDraft = EventDraft(
                title: event.title,
                eventType: event.eventType,
                startDate: event.startDate,
                isAllDay: event.isAllDay,
                endDate: event.endDate ?? event.startDate.addingTimeInterval(86_400),
                location: event.location ?? "",
                notes: event.notes ?? "",
                priority: event.priority,
                timeZoneIdentifier: event.timeZoneIdentifier
            )
            // Kue 2.0 Phase 3 — pre-fill the recurrence controls from the current rule so "This
            // and Future Occurrences" defaults to "change nothing" if the user just taps Save.
            initialDraft.applyRecurrenceRule(event.recurrence)
            _draft = State(initialValue: initialDraft)
        }
    }

    /// Phase 10 (M9) — the Share Extension's entry point. Still `.add` mode under the hood
    /// (identical `save()` path, identical duplicate-check/validation), just pre-filled with
    /// an already-parsed-and-normalized draft instead of starting from
    /// `EventDraft(eventType:)` blank — docs/09-screens-and-ux.md "same field layout as
    /// manual entry, but pre-filled," the same contract typed NL input already satisfies.
    init(prefilledDraft: EventDraft, ambiguities: [DraftAmbiguity], source: EventSource) {
        self.mode = .add(initialEventType: prefilledDraft.eventType)
        _draft = State(initialValue: prefilledDraft)
        _ambiguities = State(initialValue: ambiguities)
        _draftSource = State(initialValue: source)
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Kue 2.0 Phase 3 — the occurrence being edited, if any (nil in `.add` mode).
    private var editingEvent: KueEvent? {
        if case .edit(let event) = mode { return event }
        return nil
    }

    private var isEditingSeriesOccurrence: Bool {
        editingEvent?.seriesID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAddingNewEvent {
                    nlInputSection
                }

                if let duplicate {
                    // Kue 2.0 Phase 7 — one shared banner treatment (KueBanner) rather than a
                    // bespoke orange `Label` — same identifier, same "tap to view" affordance.
                    Section {
                        KueBanner(
                            kind: .warning,
                            message: "You already have \"\(duplicate.title)\" on this date.",
                            action: ("View Event", { isViewingDuplicate = true })
                        )
                        .accessibilityIdentifier("duplicateWarning")
                    }
                }

                Section("Event") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("eventTitleField")

                    ambiguityBanner(for: "eventType")

                    Picker("Type", selection: $draft.eventType) {
                        ForEach(EventType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .accessibilityIdentifier("eventTypePicker")

                    Picker("Priority", selection: $draft.priority) {
                        Text("Low").tag(Priority.low)
                        Text("Medium").tag(Priority.medium)
                        Text("High").tag(Priority.high)
                    }
                }

                Section("When") {
                    Toggle("All Day", isOn: $draft.isAllDay)
                        .accessibilityIdentifier("allDayToggle")

                    ambiguityBanner(for: "startDate")

                    DatePicker(
                        draft.eventType == .trip ? "Starts" : "Date",
                        selection: $draft.startDate,
                        displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("startDatePicker")

                    if draft.eventType == .trip {
                        ambiguityBanner(for: "endDate")

                        DatePicker(
                            "Returns",
                            selection: $draft.endDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .accessibilityIdentifier("endDatePicker")
                    }

                    if isEditing {
                        Picker("Timezone", selection: $draft.timeZoneIdentifier) {
                            ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { identifier in
                                Text(identifier).tag(identifier)
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField("Location (optional)", text: $draft.location)
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                recurrenceSection

                // Anything the model flagged that isn't tied to a field rendered above.
                let unplacedAmbiguities = ambiguities.filter { !["startDate", "endDate", "eventType"].contains($0.field) }
                if !unplacedAmbiguities.isEmpty {
                    Section {
                        ForEach(unplacedAmbiguities) { ambiguity in
                            ambiguityRow(ambiguity)
                        }
                    }
                    .accessibilityIdentifier("generalAmbiguities")
                }

                if !errors.isEmpty || !recurrenceErrors.isEmpty {
                    Section {
                        ForEach(errors) { error in
                            Label(error.errorDescription ?? "", systemImage: "xmark.octagon")
                                .foregroundStyle(KueColor.error)
                                .font(KueTypography.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(recurrenceErrors) { error in
                            Label(error.errorDescription ?? "", systemImage: "xmark.octagon")
                                .foregroundStyle(KueColor.error)
                                .font(KueTypography.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("validationErrors")
                }
            }
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save() }
                        .accessibilityIdentifier("saveEventButton")
                        // Requirement 8: Create stays disabled until every ambiguity banner
                        // is resolved. Also disabled mid-parse so a stray tap can't create
                        // from a draft that's about to be overwritten.
                        .disabled(!ambiguities.isEmpty || isParsing)
                }
            }
            .onChange(of: draft.title) { checkDuplicate() }
            .onChange(of: draft.startDate) { checkDuplicate() }
            .onAppear {
                checkDuplicate()
                availability = aiAvailabilityChecker.currentAvailability()
                isAIParsingEnabled = UserPreferenceStore.current(context: modelContext).aiParsingEnabled
            }
            .sheet(isPresented: $isViewingDuplicate) {
                if let duplicate {
                    NavigationStack {
                        EventDetailView(event: duplicate)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") { isViewingDuplicate = false }
                                }
                            }
                    }
                }
            }
        }
    }

    private var isAddingNewEvent: Bool {
        if case .add = mode { return true }
        return false
    }

    // MARK: - Recurrence (Kue 2.0 Phase 3 — docs/17-recurring-events.md "UI")

    @ViewBuilder
    private var recurrenceSection: some View {
        Section("Repeat") {
            if isEditingSeriesOccurrence {
                Picker("Applies To", selection: $editScope) {
                    Text("This Occurrence").tag(RecurrenceEditScope.thisOccurrence)
                    Text("This and Future Occurrences").tag(RecurrenceEditScope.thisAndFuture)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("recurrenceEditScopePicker")

                if editScope == .thisOccurrence {
                    if let rule = editingEvent?.recurrence {
                        Text(rule.summary(startDate: editingEvent?.recurrenceAnchorDate ?? draft.startDate))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    recurrenceControls
                }
            } else {
                Toggle("Repeats", isOn: $draft.isRecurring)
                    .accessibilityIdentifier("recurrenceToggle")
                if draft.isRecurring {
                    recurrenceControls
                }
            }
        }
    }

    @ViewBuilder
    private var recurrenceControls: some View {
        Picker("Frequency", selection: $draft.recurrenceFrequency) {
            ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { frequency in
                Text(frequency.displayName).tag(frequency)
            }
        }
        .accessibilityIdentifier("recurrenceFrequencyPicker")

        Stepper("Every \(draft.recurrenceInterval) \(intervalUnitLabel)", value: $draft.recurrenceInterval, in: 1...365)
            .accessibilityIdentifier("recurrenceIntervalStepper")

        Picker("Ends", selection: $draft.recurrenceEndKind) {
            ForEach(RecurrenceEndKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("recurrenceEndKindPicker")

        switch draft.recurrenceEndKind {
        case .never:
            EmptyView()
        case .onDate:
            DatePicker("End Date", selection: $draft.recurrenceEndDate, displayedComponents: [.date])
                .accessibilityIdentifier("recurrenceEndDatePicker")
        case .afterCount:
            Stepper("\(draft.recurrenceOccurrenceCount) occurrences", value: $draft.recurrenceOccurrenceCount, in: 1...999)
                .accessibilityIdentifier("recurrenceOccurrenceCountStepper")
        }

        // Requirement 11: a clear, human-readable summary before saving.
        if let rule = draft.recurrenceRule {
            Text(rule.summary(startDate: draft.startDate))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recurrenceSummary")
        }
    }

    private var intervalUnitLabel: String {
        let base = draft.recurrenceFrequency.displayName.lowercased()
        return draft.recurrenceInterval == 1 ? base : "\(base)s"
    }

    /// Recurrence-shape controls are only actually being edited (and so only need validating)
    /// in `.add` mode, when editing a plain non-recurring event, or when editing a series
    /// occurrence under "This and Future Occurrences" scope — never for a bare "This
    /// Occurrence" edit, where the rule itself isn't touched.
    private var isRecurrenceRuleEditable: Bool {
        isAddingNewEvent || !isEditingSeriesOccurrence || editScope == .thisAndFuture
    }

    // MARK: - NL input (requirements 4-6)

    @ViewBuilder
    private var nlInputSection: some View {
        Section {
            if !isAIParsingEnabled {
                Label("AI parsing is turned off in Settings — fill in the fields below manually.", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("aiParsingDisabledMessage")
            } else if availability.isAvailable {
                TextField("Describe your event, e.g. \"Interview Friday at 10\"", text: $nlText, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("nlInputField")

                HStack {
                    Button {
                        Task { await parseNLText() }
                    } label: {
                        if isParsing {
                            ProgressView()
                        } else {
                            Text("Parse with AI")
                        }
                    }
                    .accessibilityIdentifier("parseNLButton")
                    .disabled(nlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)

                    Spacer()

                    // docs/11-privacy-and-offline.md "Clear disclosure whenever AI is used" —
                    // a persistent small label near the input.
                    Text("Parsed on-device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let parseFailureMessage {
                    Text(parseFailureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("nlParseFailureMessage")
                }
            } else {
                Label(availability.message ?? "", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("nlUnavailableMessage")
            }
        } header: {
            Text("Quick Add")
        } footer: {
            // Requirement 5: manual fallback is always reachable — the fields below work
            // exactly as manual entry, parsed or not, available or not.
            Text("Or fill in the fields below manually.")
        }
    }

    /// `@available` (as opposed to inline in the button action) because `NLParsingPipeline`
    /// is `@available(iOS 26.0, *)` — the deployment target already guarantees that, but the
    /// compiler still wants the annotation at the call site since `EventFormView` itself
    /// predates Phase 7 and isn't marked.
    @available(iOS 26.0, *)
    private func parseNLText() async {
        isParsing = true
        parseFailureMessage = nil
        defer { isParsing = false }

        let outcome = await NLParsingPipeline.run(text: nlText, parser: nlParser, timeZoneIdentifier: draft.timeZoneIdentifier)
        if let newDraft = outcome.draft {
            draft = newDraft
            ambiguities = outcome.ambiguities
            draftSource = .naturalLanguage
            checkDuplicate()
        } else {
            parseFailureMessage = outcome.failureMessage
        }
    }

    // MARK: - Ambiguity banners (requirement 8)

    @ViewBuilder
    private func ambiguityBanner(for field: String) -> some View {
        if let ambiguity = ambiguities.first(where: { $0.field == field }) {
            ambiguityRow(ambiguity)
        }
    }

    private func ambiguityRow(_ ambiguity: DraftAmbiguity) -> some View {
        KueBanner(
            kind: .notice,
            message: ambiguity.question,
            systemImage: "questionmark.circle",
            action: ("Resolved", { ambiguities.removeAll { $0.id == ambiguity.id } })
        )
        .accessibilityIdentifier("ambiguity-\(ambiguity.field)")
    }

    private func checkDuplicate() {
        let excludedID: UUID? = {
            if case .edit(let event) = mode { return event.id }
            return nil
        }()
        duplicate = DuplicateDetectionService.findDuplicate(
            title: draft.title,
            startDate: draft.startDate,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            excluding: excludedID,
            excludingSeriesID: editingEvent?.seriesID,
            in: allEvents
        )
    }

    private func save() {
        errors = EventValidator.validate(draft)
        recurrenceErrors = isRecurrenceRuleEditable ? EventValidator.validateRecurrence(draft) : []
        guard errors.isEmpty, recurrenceErrors.isEmpty, ambiguities.isEmpty else {
            haptics.play(.actionFailed)
            return
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        // docs/08-notifications.md "Deduplication": "the event engine first calls
        // removePendingNotificationRequests(withIdentifiers:) for that event's prior
        // identifiers, then re-schedules from the new timeline." Captured *before*
        // `regenerateTasks` deletes the old (non-completed) tasks below — their per-task
        // `-task-<taskID>` identifiers become unreconstructable once those rows are gone, so
        // this is the only point that can still name them.
        var staleIdentifiers: [String] = []

        switch mode {
        case .add(_):
            let event = KueEvent(
                title: title,
                eventType: draft.eventType,
                startDate: draft.startDate,
                endDate: draft.eventType == .trip ? draft.endDate : nil,
                estimatedDurationMinutes: draft.eventType.defaultEstimatedDurationMinutes,
                isAllDay: draft.isAllDay,
                location: draft.location.isEmpty ? nil : draft.location,
                notes: draft.notes.isEmpty ? nil : draft.notes,
                source: draftSource,
                priority: draft.priority,
                // Kue 2.0 Phase 4 — nil for every non-Calendar-import draft; set only when
                // this draft came from CalendarImportPipeline (requirement 16: reuse this
                // exact save() path unchanged for the persistence side).
                externalCalendarEventIdentifier: draft.externalCalendarEventIdentifier,
                externalCalendarIdentifier: draft.externalCalendarIdentifier,
                externalCalendarTitle: draft.externalCalendarTitle,
                externalCalendarLastKnownModifiedAt: draft.externalCalendarLastKnownModifiedAt
            )
            EventStatusEngine.reconcile(event, now: now)
            modelContext.insert(event)
            let widgetConfiguration = WidgetConfiguration(
                event: event,
                widgetType: WidgetType.defaultType(for: draft.eventType)
            )
            modelContext.insert(widgetConfiguration)
            event.widgetConfiguration = widgetConfiguration
            SchedulingEngine.regenerateTasks(for: event, context: modelContext, now: now)
            // Kue 2.0 Phase 3 — docs/17-recurring-events.md: a brand-new recurring event
            // becomes the origin of a fresh series; the rest of the initial horizon is
            // materialized immediately, same as this event's own tasks just were.
            startSeriesIfNeeded(for: event, now: now)
        case .edit(let event):
            if event.seriesID != nil {
                // Kue 2.0 Phase 3 — route through the This Occurrence / This and Future split.
                let outcome = OccurrenceReconciliationService.applyEdit(
                    scope: editScope, to: event, values: draft, context: modelContext, now: now
                )
                staleIdentifiers = outcome.staleNotificationIdentifiers
            } else {
                event.title = title
                event.eventType = draft.eventType
                event.startDate = draft.startDate
                event.endDate = draft.eventType == .trip ? draft.endDate : nil
                event.isAllDay = draft.isAllDay
                event.location = draft.location.isEmpty ? nil : draft.location
                event.notes = draft.notes.isEmpty ? nil : draft.notes
                event.priority = draft.priority
                event.timeZoneIdentifier = draft.timeZoneIdentifier
                event.updatedAt = now
                EventStatusEngine.reconcile(event, now: now)
                staleIdentifiers = NotificationCandidateBuilder.allIdentifiers(for: event)
                // Regenerates from event.schedule.rules per docs/05-scheduling-engine.md
                // "Editing an event after its schedule is generated" — safe to call
                // unconditionally since it's a no-op for anything a completed task already covers.
                SchedulingEngine.regenerateTasks(for: event, context: modelContext, now: now)
                // Kue 2.0 Phase 3 — a plain event can start a fresh series from an edit too.
                startSeriesIfNeeded(for: event, now: now)
            }
        }

        try? modelContext.save()
        // docs/07-widget-engine.md "Refresh strategy" — a placed widget won't otherwise
        // notice this write until its own precomputed timeline next reloads.
        EventActions.reloadWidget()
        // docs/08-notifications.md requirement 3: schedule immediately on create/edit, even
        // for events weeks away — not gated by a date window. Fire-and-forget, same as
        // `reloadWidget()` above, so the sheet dismisses instantly rather than waiting on
        // notification-center round trips. This is also "the first point it's needed"
        // (docs/08 "Permission handling") for a brand-new install, so it's the one call site
        // allowed to prompt for permission.
        if !staleIdentifiers.isEmpty {
            SystemNotificationScheduler.shared.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }
        Task {
            let intensity = UserPreferenceStore.current(context: modelContext).notificationIntensity
            await NotificationEngine.reschedule(
                context: modelContext,
                intensity: intensity,
                scheduler: SystemNotificationScheduler.shared,
                requestPermissionIfNeeded: true
            )
        }
        haptics.play(.eventCreated)
        dismiss()
    }

    /// Kue 2.0 Phase 3 — turns `event` into the origin of a brand-new series when the draft's
    /// recurrence controls are on, and materializes the rest of the initial horizon. A no-op
    /// (`draft.recurrenceRule == nil`) for every non-recurring create/edit — unchanged
    /// behavior.
    private func startSeriesIfNeeded(for event: KueEvent, now: Date) {
        guard let rule = draft.recurrenceRule else { return }
        event.recurrence = rule
        event.seriesID = UUID()
        event.recurrenceAnchorDate = event.startDate
        OccurrenceReconciliationService.materializeInitialOccurrences(from: event, context: modelContext, now: now)
    }
}

#Preview("Event Form — Light") {
    EventFormView(mode: .add(initialEventType: .generic))
        .modelContainer(ModelContainerFactory.makeInMemory())
}

#Preview("Event Form — Dark") {
    EventFormView(mode: .add(initialEventType: .generic))
        .modelContainer(ModelContainerFactory.makeInMemory())
        .preferredColorScheme(.dark)
}

#Preview("Event Form — Large Dynamic Type") {
    EventFormView(mode: .add(initialEventType: .generic))
        .modelContainer(ModelContainerFactory.makeInMemory())
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
