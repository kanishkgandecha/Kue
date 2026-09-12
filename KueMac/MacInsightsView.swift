//
//  MacInsightsView.swift
//  KueMac
//
//  Kue 3.0 Phase 6 — docs/34 "Mac experience." A native macOS Settings tab (`MacSettingsView`,
//  between Account and Sync) — not an embedded copy of `InsightsView`'s iPhone layout, same
//  "native `Form`/`.formStyle(.grouped)` instead of the iPhone view" precedent every other Mac
//  Settings section (`MacAccountView`, `MacSyncView`) already establishes. Same underlying
//  `ProfileStatisticsEngine`/`StatisticsCoordinator`/`CloudStatisticsPreference` as iPhone — no
//  competing computation, no competing preference store.
//

import SwiftUI
import SwiftData
import Charts

struct MacInsightsView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Query private var events: [KueEvent]

    @State private var isCloudEnabled = CloudStatisticsPreference.current.isEnabled
    @State private var isPresentingEnableConsent = false
    @State private var isShowingSignInGuide = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteResultMessage: String?

    private var statistics: ProfileStatistics { ProfileStatisticsEngine.compute(events: events) }

    var body: some View {
        Form {
            if events.isEmpty {
                Section {
                    Text("No activity yet. Once you create and complete some events, your activity and trends will show up here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Overview") {
                    LabeledContent("Active Events", value: "\(statistics.totalActiveEvents)")
                    LabeledContent("Completed", value: "\(statistics.completedEvents)")
                    LabeledContent("Needs Review", value: "\(statistics.eventsNeedingReview)")
                    LabeledContent("Cancelled", value: "\(statistics.cancelledEvents)")
                    LabeledContent("Skipped", value: "\(statistics.skippedEvents)")
                }

                Section("Tasks") {
                    LabeledContent("Completed", value: "\(statistics.completedTasks)")
                    LabeledContent("Pending", value: "\(statistics.pendingTasks)")
                    LabeledContent("Completion Rate", value: statistics.completionRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Not enough data")
                    LabeledContent("Preparation Workload", value: "\(statistics.preparationWorkload) task\(statistics.preparationWorkload == 1 ? "" : "s")")
                    if let leadTime = statistics.averageTaskCompletionLeadTimeHours {
                        LabeledContent("Avg. Completion Lead Time", value: leadTimeText(leadTime))
                    }
                }

                Section("Upcoming") {
                    LabeledContent("Next 7 Days", value: "\(statistics.upcoming7Days)")
                    LabeledContent("Next 30 Days", value: "\(statistics.upcoming30Days)")
                    if let nearest = statistics.nearestUpcomingEvent {
                        LabeledContent("Next Up", value: "\(nearest.title) — \(nearest.isToday ? "Today" : nearest.startDate.formatted(date: .abbreviated, time: .omitted))")
                    }
                }

                Section {
                    if let current = statistics.currentCompletionStreak, let longest = statistics.longestCompletionStreak {
                        LabeledContent("Current Streak", value: "\(current)")
                        LabeledContent("Longest Streak", value: "\(longest)")
                    } else {
                        Text("Not enough resolved events yet to show a streak.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Completion Streak")
                } footer: {
                    Text("Consecutive completed events, ordered by date — a cancelled or skipped event resets it. \"Longest\" is the best run anywhere in your history, not just the most recent one.")
                }

                if !weeklyChartEntries.isEmpty {
                    Section("Weekly Activity") {
                        Chart(statistics.weeklyActivity) { bucket in
                            BarMark(x: .value("Week", bucket.weekStart, unit: .weekOfYear), y: .value("Events", bucket.completedEventCount))
                                .foregroundStyle(.blue)
                            BarMark(x: .value("Week", bucket.weekStart, unit: .weekOfYear), y: .value("Tasks", bucket.completedTaskCount))
                                .foregroundStyle(.green)
                        }
                        .chartLegend(position: .bottom)
                        .frame(height: 180)
                    }
                }

                if !completedByTypeEntries.isEmpty {
                    Section("Completed by Type") {
                        ForEach(completedByTypeEntries, id: \.0) { type, count in
                            LabeledContent(type.displayName, value: "\(count)")
                        }
                    }
                }
            }

            cloudStatisticsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Insights")
        .task { await refreshCloudStatusIfNeeded() }
        .confirmationDialog(
            "Back up your statistics to your Kue account?",
            isPresented: $isPresentingEnableConsent, titleVisibility: .visible
        ) {
            Button("Enable Cloud Statistics") { confirmEnable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kue uploads a small weekly summary — total counts, completion rates, and streaks — to your account. Event titles, notes, locations, and any other content are never uploaded.")
        }
        .confirmationDialog(
            "Delete your uploaded cloud statistics? This does not delete your account, sign you out, or remove anything on this Mac.",
            isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Cloud Statistics", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Sign In Required", isPresented: $isShowingSignInGuide) {
            Button("OK") {}
        } message: {
            Text("Sign in from the Account tab to back up your statistics — your local data is unaffected either way.")
        }
        .alert("Cloud Statistics", isPresented: Binding(get: { deleteResultMessage != nil }, set: { if !$0 { deleteResultMessage = nil } })) {
            Button("OK") { deleteResultMessage = nil }
        } message: {
            Text(deleteResultMessage ?? "")
        }
    }

    private var weeklyChartEntries: [WeeklyActivityBucket] {
        statistics.weeklyActivity.filter { $0.completedEventCount > 0 || $0.completedTaskCount > 0 }
    }

    private var completedByTypeEntries: [(EventType, Int)] {
        EventType.allCases.compactMap { type in
            let count = statistics.completedCountsByEventType[type, default: 0]
            return count > 0 ? (type, count) : nil
        }
    }

    private func leadTimeText(_ hours: Double) -> String {
        let magnitude = abs(hours)
        let unit = magnitude >= 24 ? "\(String(format: "%.1f", magnitude / 24)) day\(magnitude / 24 == 1 ? "" : "s")" : "\(String(format: "%.1f", magnitude)) hr"
        return hours >= 0 ? "\(unit) before due" : "\(unit) after due"
    }

    // MARK: - Cloud statistics

    private var cloudStatisticsSection: some View {
        Section {
            Toggle("Back Up Statistics to Your Account", isOn: cloudToggleBinding)
            if isCloudEnabled {
                if isDeleting {
                    ProgressView()
                } else {
                    Button("Delete Cloud Statistics", role: .destructive) { isConfirmingDelete = true }
                }
            }
        } header: {
            Text("Cloud Statistics")
        } footer: {
            Text("\(StatisticsCoordinator.shared.status.displayText) — only aggregate counts, rates, and streaks are ever uploaded, never event titles, notes, locations, OCR/voice text, or Calendar identifiers.")
        }
    }

    private var cloudToggleBinding: Binding<Bool> {
        Binding(
            get: { isCloudEnabled },
            set: { newValue in
                if newValue {
                    guard case .signedIn = accountCoordinator.state else {
                        isShowingSignInGuide = true
                        return
                    }
                    isPresentingEnableConsent = true
                } else {
                    isCloudEnabled = false
                    CloudStatisticsPreference.setEnabled(false)
                    StatisticsCoordinator.shared.handlePreferenceDisabled()
                }
            }
        )
    }

    private func confirmEnable() {
        isCloudEnabled = true
        CloudStatisticsPreference.setEnabled(true)
        Task { await refreshCloudStatusIfNeeded() }
    }

    private func refreshCloudStatusIfNeeded() async {
        guard CloudStatisticsPreference.current.isEnabled else { return }
        _ = await StatisticsCoordinator.shared.refreshCloudUpload(events: events, account: accountCoordinator)
    }

    private func performDelete() async {
        isDeleting = true
        let succeeded = await StatisticsCoordinator.shared.deleteCloudStatistics(account: accountCoordinator)
        isDeleting = false
        deleteResultMessage = succeeded
            ? "Cloud statistics deleted. Your local statistics and account are unaffected."
            : "Couldn't delete cloud statistics right now. Try again later."
    }
}
