//
//  MacAccountView.swift
//  KueMac
//
//  Kue 3.0 Phase 4 — docs/32 "Native macOS experience." The Mac Settings "Account" tab —
//  native `Form`/`.formStyle(.grouped)` content and sheets, not the iPhone `AccountHubView`
//  embedded (that file lives under `Kue/`, the iPhone-only target folder, and isn't part of
//  the KueMac build regardless). Same `AccountCoordinator`/`ProfileStatisticsEngine` shared
//  logic as iOS — only the presentation is platform-specific.
//

import SwiftUI
import SwiftData

struct MacAccountView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator

    var body: some View {
        Group {
            switch accountCoordinator.state {
            case .unavailable(let reason):
                MacAccountUnavailableView(reason: reason)
            case .signedOut, .authenticating:
                MacSignedOutAccountView()
            case .awaitingEmailConfirmation(let email):
                MacConfirmEmailWaitingView(email: email)
            case .passwordRecovery:
                MacSetNewPasswordView()
            case .signedIn:
                MacAccountProfileView()
            case .sessionExpired:
                MacSessionExpiredView()
            }
        }
    }
}

private struct MacAccountUnavailableView: View {
    let reason: AccountUnavailableReason

    var body: some View {
        Form {
            Section {
                Label(reason.description, systemImage: reason == .offline ? "wifi.slash" : "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("macAccountUnavailableView")
    }
}

private struct MacSignedOutAccountView: View {
    @State private var isPresentingRegistration = false
    @State private var isPresentingSignIn = false

    var body: some View {
        Form {
            Section {
                Text("Kue works fully without an account. An optional account lets you customize your username and profile — it does not upload your existing local events in this version of Kue.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Create Account…") { isPresentingRegistration = true }
                    .accessibilityIdentifier("macCreateAccountButton")
                Button("Sign In…") { isPresentingSignIn = true }
                    .accessibilityIdentifier("macSignInButton")
            } footer: {
                Text("You can always continue without an account — nothing else in Kue requires one.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPresentingRegistration) { MacRegistrationView() }
        .sheet(isPresented: $isPresentingSignIn) { MacSignInView() }
    }
}

private struct MacRegistrationView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var usernameAvailability: Bool?
    @State private var usernameCheckTask: Task<Void, Never>?

    private var emailError: String? { email.isEmpty || AccountValidation.isValidEmail(email) ? nil : "Enter a valid email address." }
    private var passwordError: String? { password.isEmpty || AccountValidation.isValidPassword(password) ? nil : "Password must be at least \(AccountValidation.minimumPasswordLength) characters." }
    private var usernameError: String? { username.isEmpty ? nil : UsernamePolicy.validationError(for: username) }
    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !username.isEmpty
            && emailError == nil && passwordError == nil && usernameError == nil
            && usernameAvailability != false && !accountCoordinator.isAuthenticating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sign-In Details") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .accessibilityIdentifier("macRegistrationEmailField")
                    if let emailError { Text(emailError).foregroundStyle(.red).font(.caption) }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("macRegistrationPasswordField")
                    if let passwordError { Text(passwordError).foregroundStyle(.red).font(.caption) }
                }
                Section("Profile") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .accessibilityIdentifier("macRegistrationUsernameField")
                        .onChange(of: username) { _, newValue in scheduleUsernameCheck(newValue) }
                    if let usernameError {
                        Text(usernameError).foregroundStyle(.red).font(.caption)
                    } else if let usernameAvailability {
                        Text(usernameAvailability ? "Username available" : "That username is already taken.")
                            .foregroundStyle(usernameAvailability ? .green : .red).font(.caption)
                    }
                    TextField("Display Name (optional)", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("macRegistrationDisplayNameField")
                }
                if let lastError = accountCoordinator.lastError {
                    Section { Text(lastError.description).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if accountCoordinator.isAuthenticating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task {
                                await accountCoordinator.signUp(
                                    email: email, password: password, username: username,
                                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName
                                )
                            }
                        }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("macSubmitRegistrationButton")
                    }
                }
            }
            .onChange(of: accountCoordinator.state) { _, newState in
                if case .awaitingEmailConfirmation = newState { dismiss() }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func scheduleUsernameCheck(_ value: String) {
        usernameCheckTask?.cancel()
        usernameAvailability = nil
        guard UsernamePolicy.isValid(value) else { return }
        usernameCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            usernameAvailability = await accountCoordinator.checkUsernameAvailability(value)
        }
    }
}

private struct MacSignInView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isPresentingForgotPassword = false

    private var canSubmit: Bool { !email.isEmpty && !password.isEmpty && !accountCoordinator.isAuthenticating }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .accessibilityIdentifier("macSignInEmailField")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("macSignInPasswordField")
                }
                Section {
                    Button("Forgot Password?") { isPresentingForgotPassword = true }
                        .accessibilityIdentifier("macForgotPasswordButton")
                }
                if let lastError = accountCoordinator.lastError {
                    Section { Text(lastError.description).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if accountCoordinator.isAuthenticating {
                        ProgressView()
                    } else {
                        Button("Sign In") { Task { await accountCoordinator.signIn(email: email, password: password) } }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("macSubmitSignInButton")
                    }
                }
            }
            .sheet(isPresented: $isPresentingForgotPassword) { MacForgotPasswordView(prefilledEmail: email) }
            .onChange(of: accountCoordinator.state) { _, newState in
                if case .signedIn = newState { dismiss() }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
    }
}

private struct MacForgotPasswordView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss
    @State var prefilledEmail: String
    @State private var didSubmit = false
    @State private var isSubmitting = false

    init(prefilledEmail: String) { self.prefilledEmail = prefilledEmail }

    var body: some View {
        NavigationStack {
            Form {
                if didSubmit {
                    Section { Label("If an account exists for that email, a reset link is on its way.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                } else {
                    Section { TextField("Email", text: $prefilledEmail).textContentType(.emailAddress).accessibilityIdentifier("macForgotPasswordEmailField") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reset Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(didSubmit ? "Done" : "Cancel") { dismiss() } }
                if !didSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send Link") {
                            Task {
                                isSubmitting = true
                                await accountCoordinator.requestPasswordReset(email: prefilledEmail)
                                isSubmitting = false
                                didSubmit = true
                            }
                        }
                        .disabled(!AccountValidation.isValidEmail(prefilledEmail) || isSubmitting)
                        .accessibilityIdentifier("macSubmitForgotPasswordButton")
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}

private struct MacConfirmEmailWaitingView: View {
    let email: String
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var didResend = false

    var body: some View {
        Form {
            Section {
                Label("Confirm your email", systemImage: "envelope.badge")
                Text("We sent a confirmation link to \(email). Click it to finish creating your account.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(didResend ? "Confirmation Email Sent" : "Resend Confirmation Email") {
                    Task { await accountCoordinator.resendConfirmationEmail(); didResend = true }
                }
                .disabled(didResend)
                .accessibilityIdentifier("macResendConfirmationButton")
                Button("Use a Different Email", role: .destructive) { accountCoordinator.cancelPendingConfirmation() }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("macConfirmEmailWaitingView")
    }
}

private struct MacSetNewPasswordView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSubmitting = false

    private var passwordsMatch: Bool { newPassword == confirmPassword }
    private var canSubmit: Bool { AccountValidation.isValidPassword(newPassword) && passwordsMatch && !isSubmitting }

    var body: some View {
        Form {
            Section("Set a New Password") {
                SecureField("New Password", text: $newPassword).accessibilityIdentifier("macNewPasswordField")
                SecureField("Confirm New Password", text: $confirmPassword).accessibilityIdentifier("macConfirmNewPasswordField")
                if !confirmPassword.isEmpty && !passwordsMatch { Text("Passwords don't match.").foregroundStyle(.red).font(.caption) }
            }
            if let lastError = accountCoordinator.lastError {
                Section { Text(lastError.description).foregroundStyle(.red) }
            }
            Section {
                Button("Save New Password") { Task { isSubmitting = true; await accountCoordinator.setNewPassword(newPassword); isSubmitting = false } }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("macSaveNewPasswordButton")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacSessionExpiredView: View {
    @State private var isPresentingSignIn = false

    var body: some View {
        Form {
            Section {
                Label("Session Expired", systemImage: "person.crop.circle.badge.exclamationmark")
                Text("Sign in again to access your account. Your local events are unaffected.").foregroundStyle(.secondary)
            }
            Section {
                Button("Sign In Again…") { isPresentingSignIn = true }
                    .accessibilityIdentifier("macSessionExpiredSignInButton")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPresentingSignIn) { MacSignInView() }
    }
}

// MARK: - Signed in

private struct MacAccountProfileView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var isPresentingEditProfile = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeleteAccount = false
    @State private var isDeletingAccount = false

    var body: some View {
        Form {
            if case .signedIn(let session, let profile) = accountCoordinator.state {
                Section("Account") {
                    LabeledContent("Username", value: profile?.username ?? "—")
                    LabeledContent("Display Name", value: profile?.displayName?.isEmpty == false ? profile!.displayName! : "Not set")
                    LabeledContent("Email", value: session.user.email)
                    LabeledContent("Email Confirmed", value: session.user.isEmailConfirmed ? "Confirmed" : "Not confirmed")
                    LabeledContent("Account Created", value: session.user.createdAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Session", value: session.isExpired() ? "Expired" : "Active")
                }
                .accessibilityIdentifier("macAccountIdentitySection")

                Section {
                    Text("See the Insights tab (in Settings) for your full activity dashboard — the same statistics engine, computed from what's on this Mac right now.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Edit Profile…") { isPresentingEditProfile = true }
                        .accessibilityIdentifier("macEditProfileButton")
                    Button("Sign Out") { isConfirmingSignOut = true }
                        .accessibilityIdentifier("macSignOutButton")
                    if isDeletingAccount {
                        ProgressView()
                    } else {
                        Button("Delete Account", role: .destructive) { isConfirmingDeleteAccount = true }
                            .accessibilityIdentifier("macDeleteAccountButton")
                    }
                }
            }
            if let lastError = accountCoordinator.lastError {
                Section { Text(lastError.description).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("macAccountProfileView")
        .sheet(isPresented: $isPresentingEditProfile) { MacEditProfileView() }
        .confirmationDialog("Sign out of Kue?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await accountCoordinator.signOut() } }
        }
        .confirmationDialog(
            "Delete your Kue account? Your remote profile is deleted permanently. Local events on this Mac are NOT deleted — cross-device sync isn't active yet.",
            isPresented: $isConfirmingDeleteAccount, titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { isDeletingAccount = true; _ = await accountCoordinator.deleteAccount(); isDeletingAccount = false }
            }
        }
    }
}

private struct MacEditProfileView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var displayName = ""
    @State private var originalUsername = ""
    @State private var usernameAvailability: Bool?
    @State private var usernameCheckTask: Task<Void, Never>?
    @State private var isSaving = false

    private var usernameError: String? { username.isEmpty ? nil : UsernamePolicy.validationError(for: username) }
    private var canSave: Bool { !username.isEmpty && usernameError == nil && (username == originalUsername || usernameAvailability != false) && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .accessibilityIdentifier("macEditUsernameField")
                        .onChange(of: username) { _, newValue in scheduleUsernameCheck(newValue) }
                    if let usernameError {
                        Text(usernameError).foregroundStyle(.red).font(.caption)
                    } else if let usernameAvailability, username != originalUsername {
                        Text(usernameAvailability ? "Username available" : "That username is already taken.")
                            .foregroundStyle(usernameAvailability ? .green : .red).font(.caption)
                    }
                    TextField("Display Name", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("macEditDisplayNameField")
                }
                if let lastError = accountCoordinator.lastError {
                    Section { Text(lastError.description).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                isSaving = true
                                let succeeded = await accountCoordinator.updateProfile(username: username, displayName: displayName)
                                isSaving = false
                                if succeeded { dismiss() }
                            }
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("macSaveProfileButton")
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 240)
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
            usernameAvailability = await accountCoordinator.checkUsernameAvailability(value)
        }
    }
}
