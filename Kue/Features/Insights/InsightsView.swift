//
//  InsightsView.swift
//  Kue
//
//  Kue 3.0 Phase 6 — docs/34 "iPhone experience." The dedicated Profile/Insights destination —
//  reachable from Settings regardless of sign-in state (requirement A: "signed-out users must
//  still receive useful statistics computed entirely from their local SwiftData store").
//  Local statistics render unconditionally from `@Query`, which SwiftData already re-invokes
//  on every relevant local change for free (requirement I) — this view never asks
//  `StatisticsCoordinator` for anything about the *local* numbers, only about the optional
//  cloud-upload status.
//
//  Deliberately a *few* understandable insights, not a dense dashboard (requirement G) — no
//  productivity score, no ranking, no gamified language anywhere in this file.
//

import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query private var events: [KueEvent]

    @State private var isCloudEnabled = CloudStatisticsPreference.current.isEnabled
    @State private var isPresentingEnableConsent = false
    @State private var isPresentingSignInGuide = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteResultMessage: String?

    private var statistics: ProfileStatistics { ProfileStatisticsEngine.compute(events: events) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if events.isEmpty {
                    emptyState
                } else {
                    metricCardsGrid
                    weeklyActivitySection
                    completionByTypeSection
                    upcomingAndWorkloadSection
                    streakSection
                }
                cloudStatisticsSection
            }
            .padding()
        }
        .background(KueColor.screenBackground)
        .navigationTitle("Insights")
        .accessibilityIdentifier("insightsView")
        .task { await refreshCloudStatusIfNeeded() }
        .confirmationDialog(
            "Back up your statistics to your Kue account?",
            isPresented: $isPresentingEnableConsent, titleVisibility: .visible
        ) {
            Button("Enable Cloud Statistics") { confirmEnable() }
                .accessibilityIdentifier("confirmEnableCloudStatisticsButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kue uploads a small weekly summary — total counts, completion rates, and streaks — to your account. Event titles, notes, locations, and any other content are never uploaded. You can turn this off or delete what's been uploaded at any time.")
        }
        .confirmationDialog(
            "Delete your uploaded cloud statistics? This does not delete your account, sign you out, or remove anything on this device.",
            isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Cloud Statistics", role: .destructive) { Task { await performDelete() } }
                .accessibilityIdentifier("confirmDeleteCloudStatisticsButton")
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isPresentingSignInGuide) {
            NavigationStack { AccountHubView() }
        }
        .alert("Cloud Statistics", isPresented: Binding(get: { deleteResultMessage != nil }, set: { if !$0 { deleteResultMessage = nil } })) {
            Button("OK") { deleteResultMessage = nil }
        } message: {
            Text(deleteResultMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Activity")
                .font(.largeTitle.bold())
            HStack(spacing: 6) {
                Image(systemName: isCloudEnabled ? "checkmark.icloud" : "iphone")
                Text(isCloudEnabled ? "Synced to your account" : "Local Only — this device")
            }
            .font(.subheadline)
            .foregroundStyle(KueColor.secondaryText)
            .accessibilityIdentifier("insightsSyncIndicator")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Activity Yet",
            systemImage: "chart.bar.xaxis",
            description: Text("Once you create and complete some events, your activity and trends will show up here.")
        )
        .padding(.top, 40)
    }

    // MARK: - Metric cards

    private var metricCardsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(title: "Active Events", value: "\(statistics.totalActiveEvents)", systemImage: "calendar")
            metricCard(title: "Completed", value: "\(statistics.completedEvents)", systemImage: "checkmark.circle")
            metricCard(title: "Needs Review", value: "\(statistics.eventsNeedingReview)", systemImage: "questionmark.circle")
            metricCard(title: "Cancelled / Skipped", value: "\(statistics.cancelledEvents) / \(statistics.skippedEvents)", systemImage: "xmark.circle")
            metricCard(
                title: "Task Completion", value: statistics.completionRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Not enough data",
                systemImage: "checklist"
            )
            metricCard(title: "Tasks Pending", value: "\(statistics.pendingTasks)", systemImage: "clock")
        }
    }

    private func metricCard(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(KueColor.secondaryText)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .kueGlassSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Weekly activity

    private var weeklyActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Activity")
                .font(.headline)
            if statistics.weeklyActivity.allSatisfy({ $0.completedEventCount == 0 && $0.completedTaskCount == 0 }) {
                Text("No completions in the last 8 weeks yet.")
                    .font(.footnote)
                    .foregroundStyle(KueColor.secondaryText)
            } else {
                Chart(statistics.weeklyActivity) { bucket in
                    BarMark(
                        x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                        y: .value("Events Completed", bucket.completedEventCount)
                    )
                    .foregroundStyle(KueColor.accent)
                    BarMark(
                        x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                        y: .value("Tasks Completed", bucket.completedTaskCount)
                    )
                    .foregroundStyle(KueColor.completed)
                }
                .chartLegend(position: .bottom)
                .frame(height: 160)
                .accessibilityLabel("Weekly completions, last 8 weeks")
                .accessibilityValue(weeklyActivityAccessibilitySummary)
            }
        }
        .padding()
        .kueGlassSurface()
    }

    private var weeklyActivityAccessibilitySummary: String {
        statistics.weeklyActivity.map { bucket in
            "\(bucket.weekStart.formatted(date: .abbreviated, time: .omitted)): \(bucket.completedEventCount) events, \(bucket.completedTaskCount) tasks"
        }.joined(separator: "; ")
    }

    // MARK: - Completion by type

    private var completionByTypeSection: some View {
        let entries = EventType.allCases.compactMap { type -> (EventType, Int)? in
            let count = statistics.completedCountsByEventType[type, default: 0]
            return count > 0 ? (type, count) : nil
        }
        return Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Completed by Type")
                        .font(.headline)
                    ForEach(entries, id: \.0) { type, count in
                        HStack {
                            Circle().fill(EventTypeAccent.color(for: type)).frame(width: 10, height: 10)
                            Text(type.displayName)
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(KueColor.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
                .kueGlassSurface()
            }
        }
    }

    // MARK: - Upcoming and preparation workload

    private var upcomingAndWorkloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming")
                .font(.headline)
            LabeledContent("Next 7 Days", value: "\(statistics.upcoming7Days)")
            LabeledContent("Next 30 Days", value: "\(statistics.upcoming30Days)")
            LabeledContent("Preparation Workload", value: "\(statistics.preparationWorkload) task\(statistics.preparationWorkload == 1 ? "" : "s")")
            if let nearest = statistics.nearestUpcomingEvent {
                LabeledContent("Next Up", value: "\(nearest.title) — \(nearest.isToday ? "Today" : nearest.startDate.formatted(date: .abbreviated, time: .omitted))")
            }
            if let leadTime = statistics.averageTaskCompletionLeadTimeHours {
                LabeledContent("Avg. Task Lead Time", value: leadTimeText(leadTime))
            }
        }
        .padding()
        .kueGlassSurface()
    }

    private func leadTimeText(_ hours: Double) -> String {
        let magnitude = abs(hours)
        let unit = magnitude >= 24 ? "\(String(format: "%.1f", magnitude / 24)) day\(magnitude / 24 == 1 ? "" : "s")" : "\(String(format: "%.1f", magnitude)) hr"
        return hours >= 0 ? "\(unit) before due" : "\(unit) after due"
    }

    // MARK: - Streak

    private var streakSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Completion Streak")
                    .font(.headline)
                Spacer()
            }
            if let current = statistics.currentCompletionStreak, let longest = statistics.longestCompletionStreak {
                LabeledContent("Current", value: "\(current)")
                LabeledContent("Longest", value: "\(longest)")
            } else {
                Text("Not enough resolved events yet to show a streak.")
                    .font(.footnote)
                    .foregroundStyle(KueColor.secondaryText)
            }
            Text("A streak counts consecutive completed events, ordered by date, with a cancelled or skipped event resetting it. \"Longest\" is the best run found anywhere in your history, not just the most recent one.")
                .font(.caption2)
                .foregroundStyle(KueColor.secondaryText)
        }
        .padding()
        .kueGlassSurface()
    }

    // MARK: - Cloud statistics

    private var cloudStatisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cloud Statistics")
                    .font(.headline)
                Spacer()
                Text(StatisticsCoordinator.shared.status.displayText)
                    .font(.caption)
                    .foregroundStyle(StatisticsCoordinator.shared.status.isErrorLike ? KueColor.warning : KueColor.secondaryText)
                    .accessibilityIdentifier("cloudStatisticsStatusLabel")
            }
            Toggle("Back Up Statistics to Your Account", isOn: cloudToggleBinding)
                .accessibilityIdentifier("cloudStatisticsToggle")
            Text("Only aggregate counts, rates, and streaks — never event titles, notes, locations, OCR/voice text, or Calendar identifiers.")
                .font(.footnote)
                .foregroundStyle(KueColor.secondaryText)
            if isCloudEnabled {
                if isDeleting {
                    ProgressView()
                } else {
                    Button("Delete Cloud Statistics", role: .destructive) { isConfirmingDelete = true }
                        .accessibilityIdentifier("deleteCloudStatisticsButton")
                }
            }
        }
        .padding()
        .kueGlassSurface()
    }

    private var cloudToggleBinding: Binding<Bool> {
        Binding(
            get: { isCloudEnabled },
            set: { newValue in
                if newValue {
                    guard case .signedIn = accountCoordinator.state else {
                        // Requirement F: "guide them to sign in without losing local data" —
                        // never flips the preference on while signed out.
                        isPresentingSignInGuide = true
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

#Preview("Insights") {
    NavigationStack { InsightsView() }
        .modelContainer(ModelContainerFactory.makeInMemory())
        .environment(AccountCoordinator(provider: FakeAccountProvider(), secureStore: FakeSecureStore()))
}
