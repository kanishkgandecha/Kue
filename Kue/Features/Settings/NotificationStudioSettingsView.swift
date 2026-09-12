//
//  NotificationStudioSettingsView.swift
//  Kue
//
//  Kue 3.0 Phase 3 — docs/31-kue-3-notification-studio.md "Notification Studio destinations" /
//  "Global settings". The iPhone Settings → Notifications → Notification Studio destination —
//  every global default this phase adds, all backed by `NotificationGlobalPreferences`
//  (App Group `UserDefaults`, per-device by construction — see that type's own header).
//  Changing a value here never touches an existing event's own `NotificationRule` rows —
//  "Apply new defaults to existing events…" below is the one explicit, confirmed operation that
//  does, matching docs/31's "must not silently rewrite existing events" requirement.
//

import SwiftUI
import SwiftData

struct NotificationStudioSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var preferences = NotificationGlobalPreferences.current
    @State private var isShowingApplyToExistingSheet = false

    var body: some View {
        Form {
            Section {
                Toggle("Kue Notifications", isOn: binding(\.masterEnabled))
                    .accessibilityIdentifier("masterNotificationsToggle")
                Toggle("Deliver on This Device", isOn: binding(\.deliverOnThisDevice))
                    .accessibilityIdentifier("deliverOnThisDeviceToggle")
            } footer: {
                Text("\"Deliver on This Device\" only affects this iPhone or Mac — it is not synced. If you turn it on for more than one of your devices, you may see the same reminder on each of them.")
            }

            Section("Default Event Rules") {
                Picker("Before Event Start", selection: binding(\.defaultPreEventMinutes)) {
                    ForEach(ReminderPreference.availableOptions, id: \.self) { minutes in
                        Text(ReminderPreference.displayName(forMinutes: minutes)).tag(minutes)
                    }
                }
                Toggle("Outcome Follow-Up (\"How did it go?\")", isOn: binding(\.defaultOutcomeFollowUpEnabled))
            }

            Section("Default Task Rules") {
                Picker("Before Task Due", selection: binding(\.defaultTaskReminderMinutesBeforeDue)) {
                    Text("At due time").tag(Int?.none)
                    Text("15 minutes before").tag(Int?.some(15))
                    Text("30 minutes before").tag(Int?.some(30))
                    Text("1 hour before").tag(Int?.some(60))
                }
            }

            Section {
                DatePicker("Preferred Time", selection: allDayPreferredTimeBinding, displayedComponents: .hourAndMinute)
            } header: {
                Text("All-Day Events")
            } footer: {
                Text("All-day events have no clock time of their own, so reminders that reference \"event start\" use this time instead of midnight.")
            }

            // Kue 3.0 Phase 7 — docs/35 "Notification Control Center." The new Event Type
            // scope — precedence `Specific Event > Event Type > Global Default`.
            Section {
                ForEach(EventType.allCases, id: \.self) { eventType in
                    NavigationLink(eventType.displayName) {
                        EventTypeNotificationRulesView(eventType: eventType)
                    }
                }
            } header: {
                Text("Event Type Overrides")
            } footer: {
                Text("Rules here apply to every event of that type, unless a specific event overrides them.")
            }

            dailySummarySection
            weeklySummarySection

            quietHoursSection

            Section("Sound & Presentation") {
                Picker("Sound", selection: binding(\.soundPreference)) {
                    Text("Default").tag(NotificationSoundOption.defaultSound)
                    Text("Silent").tag(NotificationSoundOption.silent)
                }
                Toggle("Badge App Icon", isOn: binding(\.badgeEnabled))
                Toggle("Group by Event", isOn: binding(\.groupNotificationsByEvent))
                Toggle("Time-Sensitive", isOn: binding(\.timeSensitiveEnabled))
                Toggle("Reduce on Weekends", isOn: Binding(
                    get: { !preferences.nonEssentialNotificationsOnWeekends },
                    set: { preferences.nonEssentialNotificationsOnWeekends = !$0; save() }
                ))
            }

            Section {
                Picker("Notification Previews", selection: binding(\.previewPrivacy)) {
                    Text("Full").tag(NotificationPreviewPrivacy.full)
                    Text("Event Only").tag(NotificationPreviewPrivacy.eventOnly)
                    Text("Private").tag(NotificationPreviewPrivacy.private)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text(previewPrivacyExplanation)
            }

            Section {
                Button("Apply New Defaults to Existing Events…") {
                    isShowingApplyToExistingSheet = true
                }
                .accessibilityIdentifier("applyDefaultsToExistingEventsButton")
            } footer: {
                Text("Global defaults above only affect events you create from now on. Use this to review and optionally apply them to events you already have.")
            }
        }
        .navigationTitle("Notifications")
        .sheet(isPresented: $isShowingApplyToExistingSheet) {
            ApplyDefaultsToExistingEventsView(preferences: preferences)
        }
    }

    // MARK: - Daily / Weekly Summary (Kue 3.0 Phase 7 — docs/35)

    private var dailySummarySection: some View {
        Section {
            Toggle("Daily Summary", isOn: Binding(
                get: { preferences.effectiveDailySummary.isEnabled },
                set: { var s = preferences.effectiveDailySummary; s.isEnabled = $0; preferences.dailySummary = s; save() }
            ))
            .accessibilityIdentifier("dailySummaryToggle")
            if preferences.effectiveDailySummary.isEnabled {
                DatePicker("Delivery Time", selection: minuteBinding(
                    get: { preferences.effectiveDailySummary.deliveryMinuteOfDay },
                    set: { var s = preferences.effectiveDailySummary; s.deliveryMinuteOfDay = $0; preferences.dailySummary = s }
                ), displayedComponents: .hourAndMinute)
                Picker("Covers", selection: Binding(
                    get: { preferences.effectiveDailySummary.scope },
                    set: { var s = preferences.effectiveDailySummary; s.scope = $0; preferences.dailySummary = s; save() }
                )) {
                    Text("Today").tag(DailySummaryScope.today)
                    Text("Tomorrow").tag(DailySummaryScope.tomorrow)
                }
            }
        } header: {
            Text("Daily Summary")
        } footer: {
            Text("A single reminder with just a count — never event titles or notes.")
        }
    }

    private var weeklySummarySection: some View {
        Section {
            Toggle("Weekly Summary", isOn: Binding(
                get: { preferences.effectiveWeeklySummary.isEnabled },
                set: { var s = preferences.effectiveWeeklySummary; s.isEnabled = $0; preferences.weeklySummary = s; save() }
            ))
            .accessibilityIdentifier("weeklySummaryToggle")
            if preferences.effectiveWeeklySummary.isEnabled {
                Picker("Day", selection: Binding(
                    get: { preferences.effectiveWeeklySummary.weekday },
                    set: { var s = preferences.effectiveWeeklySummary; s.weekday = $0; preferences.weeklySummary = s; save() }
                )) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }
                DatePicker("Delivery Time", selection: minuteBinding(
                    get: { preferences.effectiveWeeklySummary.deliveryMinuteOfDay },
                    set: { var s = preferences.effectiveWeeklySummary; s.deliveryMinuteOfDay = $0; preferences.weeklySummary = s }
                ), displayedComponents: .hourAndMinute)
                Stepper("Next \(preferences.effectiveWeeklySummary.upcomingWindowDays) days", value: Binding(
                    get: { preferences.effectiveWeeklySummary.upcomingWindowDays },
                    set: { var s = preferences.effectiveWeeklySummary; s.upcomingWindowDays = $0; preferences.weeklySummary = s; save() }
                ), in: 1...30)
            }
        } header: {
            Text("Weekly Summary")
        } footer: {
            Text("A single reminder with just a count of what's coming up — never event titles or notes.")
        }
    }

    private func minuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: get() / 60, minute: get() % 60, second: 0, of: .now) ?? .now },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                set((components.hour ?? 0) * 60 + (components.minute ?? 0))
                save()
            }
        )
    }

    // MARK: - Quiet hours

    private var quietHoursSection: some View {
        Section {
            Toggle("Quiet Hours", isOn: binding(\.quietHours.isEnabled))
                .accessibilityIdentifier("quietHoursToggle")
            if preferences.quietHours.isEnabled {
                DatePicker("Starts", selection: quietHoursTimeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: quietHoursTimeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                Toggle("Allow Event-Start Notifications", isOn: binding(\.quietHours.allowEventStartThrough))
                Toggle("Allow Time-Sensitive Notifications", isOn: binding(\.quietHours.allowTimeSensitiveThrough))
                weekdayPicker
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            Text("A reminder due during quiet hours is delivered right when quiet hours end, not silently dropped.")
        }
    }

    private var weekdayPicker: some View {
        let symbols = Calendar.current.weekdaySymbols // index 0 = Sunday, matching Calendar.Component.weekday's 1-based values offset by 1
        return ForEach(1...7, id: \.self) { weekday in
            Toggle(symbols[weekday - 1], isOn: Binding(
                get: { preferences.quietHours.enabledWeekdays.contains(weekday) },
                set: { isOn in
                    if isOn { preferences.quietHours.enabledWeekdays.insert(weekday) }
                    else { preferences.quietHours.enabledWeekdays.remove(weekday) }
                    save()
                }
            ))
        }
    }

    private func quietHoursTimeBinding(_ keyPath: WritableKeyPath<NotificationQuietHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = preferences.quietHours[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                preferences.quietHours[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                save()
            }
        )
    }

    private var allDayPreferredTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minute = preferences.allDayPreferredMinuteOfDay
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                preferences.allDayPreferredMinuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                save()
            }
        )
    }

    private var previewPrivacyExplanation: String {
        switch preferences.previewPrivacy {
        case .full: return "Notifications show the real event and task names."
        case .eventOnly: return "Notifications show the event name; task-specific reminders use generic text."
        case .private: return "Notifications never show event or task names — just \"You have a Kue reminder.\""
        }
    }

    // MARK: - Persistence

    private func binding<Value>(_ keyPath: WritableKeyPath<NotificationGlobalPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { preferences[keyPath: keyPath] = $0; save() })
    }

    private func save() {
        NotificationGlobalPreferences.save(preferences)
        Task {
            await NotificationEngine.reschedule(context: modelContext, intensity: UserPreferenceStore.current(context: modelContext).notificationIntensity, scheduler: SystemNotificationScheduler.shared, globalPreferences: preferences)
        }
    }
}
