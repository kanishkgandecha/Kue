//
//  AccountHubView.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32-kue-3-accounts-and-backend-foundation.md "iPhone experience."
//  Settings' "Account" destination — dispatches on `AccountCoordinator.state` to the matching
//  screen. `.authenticating` intentionally renders the same as `.signedOut` here: it only ever
//  happens while `RegistrationView`/`SignInView` is presented as a sheet *on top* of whatever
//  this dispatcher shows underneath, so the sheet (not this switch) is what the user actually
//  sees mid-submit — matching every other sheet-based flow in this codebase
//  (`NotificationRuleEditorView`, `ApplyDefaultsToExistingEventsView`, ...) rather than a
//  nested push/pop dance that would fight this view's own state-driven re-render.
//

import SwiftUI

struct AccountHubView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator

    var body: some View {
        Group {
            switch accountCoordinator.state {
            case .unavailable(let reason):
                AccountUnavailableView(reason: reason)
            case .signedOut, .authenticating:
                SignedOutAccountView()
            case .awaitingEmailConfirmation(let email):
                ConfirmEmailWaitingView(email: email)
            case .passwordRecovery:
                SetNewPasswordView()
            case .signedIn:
                AccountProfileView()
            case .sessionExpired:
                SessionExpiredView()
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Unavailable

struct AccountUnavailableView: View {
    let reason: AccountUnavailableReason

    var body: some View {
        ContentUnavailableView(
            "Accounts Unavailable", systemImage: reason == .offline ? "wifi.slash" : "person.crop.circle.badge.xmark",
            description: Text(reason.description)
        )
        .accessibilityIdentifier("accountUnavailableView")
    }
}

// MARK: - Signed out

struct SignedOutAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingRegistration = false
    @State private var isPresentingSignIn = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: KueSpacing.sm) {
                    Text("Kue works fully without an account.")
                        .font(KueTypography.cardTitle)
                    Text("An optional account lets you customize your username and profile. Creating one does not upload your existing local events in this version of Kue — that's coming in a future update.")
                        .font(KueTypography.footnote)
                        .foregroundStyle(KueColor.secondaryText)
                }
                .padding(.vertical, KueSpacing.xs)
            }

            Section {
                Button("Create Account") { isPresentingRegistration = true }
                    .accessibilityIdentifier("createAccountButton")
                Button("Sign In") { isPresentingSignIn = true }
                    .accessibilityIdentifier("signInButton")
            }

            Section {
                Button("Continue Without an Account") { dismiss() }
                    .accessibilityIdentifier("continueWithoutAccountButton")
            }
        }
        .sheet(isPresented: $isPresentingRegistration) { RegistrationView() }
        .sheet(isPresented: $isPresentingSignIn) { SignInView() }
    }
}

// MARK: - Registration

struct RegistrationView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var username = ""
    @State private var displayName = ""
    @State private var usernameAvailability: Bool?
    @State private var usernameCheckTask: Task<Void, Never>?

    private var emailError: String? {
        email.isEmpty || AccountValidation.isValidEmail(email) ? nil : "Enter a valid email address."
    }
    private var passwordError: String? {
        password.isEmpty || AccountValidation.isValidPassword(password) ? nil : "Password must be at least \(AccountValidation.minimumPasswordLength) characters."
    }
    private var usernameError: String? {
        username.isEmpty ? nil : UsernamePolicy.validationError(for: username)
    }
    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !username.isEmpty
            && emailError == nil && passwordError == nil && usernameError == nil
            && usernameAvailability != false && !accountCoordinator.isAuthenticating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("registrationEmailField")
                    if let emailError { KueBanner(kind: .error, message: emailError) }

                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .accessibilityIdentifier("registrationPasswordField")
                        
                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                    if let passwordError { KueBanner(kind: .error, message: passwordError) }
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("registrationUsernameField")
                        .onChange(of: username) { _, newValue in scheduleUsernameCheck(newValue) }
                    if let usernameError {
                        KueBanner(kind: .error, message: usernameError)
                    } else if let usernameAvailability {
                        KueBanner(kind: usernameAvailability ? .notice : .error, message: usernameAvailability ? "Username available" : "That username is already taken.")
                    }
                    TextField("Display Name (optional)", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("registrationDisplayNameField")
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Usernames are 3–20 characters: lowercase letters, numbers, and underscores.")
                }

                if let lastError = accountCoordinator.lastError {
                    Section {
                        KueBanner(kind: .error, message: lastError.description)
                            .accessibilityIdentifier("registrationErrorBanner")
                    }
                }
            }
            .navigationTitle("Create Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if accountCoordinator.isAuthenticating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("submitRegistrationButton")
                    }
                }
            }
            .onChange(of: accountCoordinator.state) { _, newState in
                if case .awaitingEmailConfirmation = newState { dismiss() }
            }
        }
    }

    /// Debounced (requirement N: never a network call on every keystroke/body render) — a
    /// fresh check cancels whatever the previous one was still waiting on.
    private func scheduleUsernameCheck(_ value: String) {
        usernameCheckTask?.cancel()
        usernameAvailability = nil
        guard UsernamePolicy.isValid(value) else { return }
        usernameCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let available = await accountCoordinator.checkUsernameAvailability(value)
            guard !Task.isCancelled else { return }
            usernameAvailability = available
        }
    }

    private func submit() async {
        await accountCoordinator.signUp(
            email: email, password: password, username: username,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName
        )
    }
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isPresentingForgotPassword = false

    private var canSubmit: Bool { !email.isEmpty && !password.isEmpty && !accountCoordinator.isAuthenticating }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("signInEmailField")
                    HStack {
                        Group {
                            if isPasswordVisible { TextField("Password", text: $password) }
                            else { SecureField("Password", text: $password) }
                        }
                        .textContentType(.password)
                        .accessibilityIdentifier("signInPasswordField")
                        Button { isPasswordVisible.toggle() } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                }

                Section {
                    Button("Forgot Password?") { isPresentingForgotPassword = true }
                        .accessibilityIdentifier("forgotPasswordButton")
                }

                if let lastError = accountCoordinator.lastError {
                    Section {
                        KueBanner(kind: .error, message: lastError.description)
                            .accessibilityIdentifier("signInErrorBanner")
                    }
                }
            }
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if accountCoordinator.isAuthenticating {
                        ProgressView()
                    } else {
                        Button("Sign In") { Task { await accountCoordinator.signIn(email: email, password: password) } }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("submitSignInButton")
                    }
                }
            }
            .sheet(isPresented: $isPresentingForgotPassword) { ForgotPasswordView(prefilledEmail: email) }
            .onChange(of: accountCoordinator.state) { _, newState in
                if case .signedIn = newState { dismiss() }
            }
        }
    }
}

// MARK: - Forgot password

struct ForgotPasswordView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var didSubmit = false
    @State private var isSubmitting = false

    init(prefilledEmail: String = "") {
        _email = State(initialValue: prefilledEmail)
    }

    var body: some View {
        NavigationStack {
            Form {
                if didSubmit {
                    Section {
                        Label("If an account exists for that email, a reset link is on its way.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("forgotPasswordEmailField")
                    } footer: {
                        Text("We'll email you a link to reset your password.")
                    }
                    if let lastError = accountCoordinator.lastError {
                        Section { KueBanner(kind: .error, message: lastError.description) }
                    }
                }
            }
            .navigationTitle("Reset Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                if !didSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button("Send Link") {
                                Task {
                                    isSubmitting = true
                                    await accountCoordinator.requestPasswordReset(email: email)
                                    isSubmitting = false
                                    didSubmit = true
                                }
                            }
                            .disabled(!AccountValidation.isValidEmail(email))
                            .accessibilityIdentifier("submitForgotPasswordButton")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Confirm email waiting

struct ConfirmEmailWaitingView: View {
    let email: String
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var didResend = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: KueSpacing.sm) {
                    Label("Confirm Your Email", systemImage: "envelope.badge")
                        .font(KueTypography.cardTitle)
                    Text("We sent a confirmation link to \(email). Tap it to finish creating your account.")
                        .font(KueTypography.footnote)
                        .foregroundStyle(KueColor.secondaryText)
                }
                .padding(.vertical, KueSpacing.xs)
                .accessibilityIdentifier("confirmEmailWaitingView")
            }

            Section {
                Button(didResend ? "Confirmation Email Sent" : "Resend Confirmation Email") {
                    Task {
                        await accountCoordinator.resendConfirmationEmail()
                        didResend = true
                    }
                }
                .disabled(didResend)
                .accessibilityIdentifier("resendConfirmationButton")
                Button("Use a Different Email", role: .destructive) {
                    accountCoordinator.cancelPendingConfirmation()
                }
                .accessibilityIdentifier("useDifferentEmailButton")
            }

            if let lastError = accountCoordinator.lastError {
                Section { KueBanner(kind: .error, message: lastError.description) }
            }
        }
    }
}

// MARK: - Set new password (password-recovery callback)

struct SetNewPasswordView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSubmitting = false

    private var passwordsMatch: Bool { newPassword == confirmPassword }
    private var canSubmit: Bool { AccountValidation.isValidPassword(newPassword) && passwordsMatch && !isSubmitting }

    var body: some View {
        Form {
            Section {
                SecureField("New Password", text: $newPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("newPasswordField")
                SecureField("Confirm New Password", text: $confirmPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("confirmNewPasswordField")
                if !confirmPassword.isEmpty && !passwordsMatch {
                    KueBanner(kind: .error, message: "Passwords don't match.")
                }
            } header: {
                Text("Set a New Password")
            }

            if let lastError = accountCoordinator.lastError {
                Section { KueBanner(kind: .error, message: lastError.description) }
            }

            Section {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("Save New Password") {
                        Task {
                            isSubmitting = true
                            await accountCoordinator.setNewPassword(newPassword)
                            isSubmitting = false
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("saveNewPasswordButton")
                }
            }
        }
    }
}

// MARK: - Session expired

struct SessionExpiredView: View {
    @Environment(AccountCoordinator.self) private var accountCoordinator
    @State private var isPresentingSignIn = false

    var body: some View {
        List {
            Section {
                ContentUnavailableView(
                    "Session Expired", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Sign in again to access your account. Your local events are unaffected.")
                )
            }
            Section {
                Button("Sign In Again") { isPresentingSignIn = true }
                    .accessibilityIdentifier("sessionExpiredSignInButton")
            }
        }
        .sheet(isPresented: $isPresentingSignIn) { SignInView() }
    }
}
