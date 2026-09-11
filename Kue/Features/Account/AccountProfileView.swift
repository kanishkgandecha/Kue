//
//  AccountProfileView.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "iPhone experience." The signed-in half of `AccountHubView`'s
//  dispatch: profile identity, session status, local usage statistics
//  (`ProfileStatisticsEngine`, computed from the already-open SwiftData store — never
//  uploaded), edit, sign-out, and account deletion.
//

import SwiftUI
import SwiftData

struct AccountProfileView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Query private var events: [KueEvent]
    @State private var isPresentingEditProfile = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeleteAccount = false
    @State private var isDeletingAccount = false

    private var statistics: ProfileStatistics { ProfileStatisticsEngine.compute(events: events) }

    var body: some View {
        List {
            if case .signedIn(let session, let profile) = accountCoordinator.state {
                identitySection(session: session, profile: profile)
                statisticsSection
                actionsSection
            }

            if let lastError = accountCoordinator.lastError {
                Section { KueBanner(kind: .error, message: lastError.description) }
            }
        }
        .accessibilityIdentifier("accountProfileView")
        .sheet(isPresented: $isPresentingEditProfile) { EditProfileView() }
        .confirmationDialog("Sign out of Kue?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await accountCoordinator.signOut() } }
                .accessibilityIdentifier("confirmSignOutButton")
        }
        .confirmationDialog(
            "Delete your Kue account? Your remote profile is deleted permanently. Local events on this device are NOT deleted — cross-device sync isn't active yet, so nothing else changes unless you separately use Settings' \"Delete Everything.\"",
            isPresented: $isConfirmingDeleteAccount, titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task {
                    isDeletingAccount = true
                    _ = await accountCoordinator.deleteAccount()
                    isDeletingAccount = false
                }
            }
            .accessibilityIdentifier("confirmDeleteAccountButton")
        }
    }

    @ViewBuilder
    private func identitySection(session: AccountSession, profile: AccountProfile?) -> some View {
        Section {
            LabeledContent("Username", value: profile?.username ?? "—")
            LabeledContent("Display Name", value: profile?.displayName?.isEmpty == false ? profile!.displayName! : "Not set")
            LabeledContent("Email", value: session.user.email)
            LabeledContent("Email Confirmed") {
                Label(session.user.isEmailConfirmed ? "Confirmed" : "Not confirmed", systemImage: session.user.isEmailConfirmed ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(session.user.isEmailConfirmed ? .green : .orange)
            }
            LabeledContent("Account Created", value: session.user.createdAt.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Session", value: session.isExpired() ? "Expired" : "Active")
        } header: {
            Text("Account")
        } footer: {
            if profile == nil {
                Text("Setting up your profile…")
            }
        }
    }

    private var statisticsSection: some View {
        Section {
            LabeledContent("Active Events", value: "\(statistics.totalActiveEvents)")
            LabeledContent("Upcoming", value: "\(statistics.upcomingEvents)")
            LabeledContent("Needs Review", value: "\(statistics.eventsNeedingReview)")
            LabeledContent("Completed", value: "\(statistics.completedEvents)")
            LabeledContent("Tasks Completed", value: "\(statistics.completedTasks)")
            LabeledContent("Tasks Pending", value: "\(statistics.pendingTasks)")
            if let rate = statistics.completionRate {
                LabeledContent("Task Completion Rate", value: rate.formatted(.percent.precision(.fractionLength(0))))
            }
            if let nearest = statistics.nearestUpcomingEvent {
                LabeledContent("Next Up", value: "\(nearest.title) — \(nearest.isToday ? "Today" : nearest.startDate.formatted(date: .abbreviated, time: .omitted))")
            }
            if let streak = statistics.preparationStreak, streak > 0 {
                LabeledContent("Completion Streak", value: "\(streak)")
            }
            ForEach(EventType.allCases.filter { statistics.countsByEventType[$0, default: 0] > 0 }, id: \.self) { type in
                LabeledContent(type.displayName, value: "\(statistics.countsByEventType[type, default: 0])")
            }
        } header: {
            Text("Your Kue Activity")
        } footer: {
            Text("Computed from what's on this device right now — never uploaded.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Edit Profile") { isPresentingEditProfile = true }
                .accessibilityIdentifier("editProfileButton")
            Button("Sign Out") { isConfirmingSignOut = true }
                .accessibilityIdentifier("signOutButton")
            if isDeletingAccount {
                ProgressView()
            } else {
                Button("Delete Account", role: .destructive) { isConfirmingDeleteAccount = true }
                    .accessibilityIdentifier("deleteAccountButton")
            }
        }
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var displayName = ""
    @State private var usernameAvailability: Bool?
    @State private var usernameCheckTask: Task<Void, Never>?
    @State private var isSaving = false
    /// Filled from the coordinator's own state in `.task` below, alongside `username`/
    /// `displayName` — this default keeps the view constructible without a session,
    /// matching every other Kue form's own "start empty, hydrate on appear" shape.
    @State private var originalUsername = ""

    private var usernameError: String? {
        username.isEmpty ? nil : UsernamePolicy.validationError(for: username)
    }
    private var canSave: Bool {
        !username.isEmpty && usernameError == nil && (username == originalUsername || usernameAvailability != false) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("editUsernameField")
                        .onChange(of: username) { _, newValue in scheduleUsernameCheck(newValue) }
                    if let usernameError {
                        KueBanner(kind: .error, message: usernameError)
                    } else if let usernameAvailability, username != originalUsername {
                        KueBanner(kind: usernameAvailability ? .notice : .error, message: usernameAvailability ? "Username available" : "That username is already taken.")
                    }
                    TextField("Display Name", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("editDisplayNameField")
                }

                if let lastError = accountCoordinator.lastError {
                    Section { KueBanner(kind: .error, message: lastError.description) }
                }
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!canSave)
                            .accessibilityIdentifier("saveProfileButton")
                    }
                }
            }
        }
        .task {
            if case .signedIn(_, let profile) = accountCoordinator.state, let profile {
                username = profile.username
                originalUsername = profile.username
                displayName = profile.displayName ?? ""
            }
        }
    }

    private func scheduleUsernameCheck(_ value: String) {
        usernameCheckTask?.cancel()
        usernameAvailability = nil
        guard value != originalUsername, UsernamePolicy.isValid(value) else { return }
        usernameCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let available = await accountCoordinator.checkUsernameAvailability(value)
            guard !Task.isCancelled else { return }
            usernameAvailability = available
        }
    }

    private func save() async {
        isSaving = true
        let succeeded = await accountCoordinator.updateProfile(username: username, displayName: displayName)
        isSaving = false
        if succeeded { dismiss() }
    }
}
