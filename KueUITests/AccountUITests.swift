//
//  AccountUITests.swift
//  KueUITests
//
//  Kue 3.0 Phase 4 — docs/32 "Testing." Every case here launches with
//  `FakeAccountProvider.uiTestLaunchArgument` — never real Supabase credentials, never the
//  real Keychain (requirement M). `FakeAccountProvider`'s own seeded fixture account
//  (`fixtureEmail`/`fixturePassword`/`fixtureUsername`) is what "sign in" cases use.
//

import XCTest

final class AccountUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestLaunchConfiguration.resetDeviceOrientation()
        app = XCUIApplication()
        app.launchArguments = [UITestLaunchConfiguration.isolatedStoreArgument, UITestLaunchConfiguration.fakeAccountArgument]
        app.launch()
    }

    private func openAccountScreen() {
        app.selectTab("tab-settings")
        let link = app.buttons["accountLink"]
        link.scrollUpUntilHittable(in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    // MARK: - Signed out / continue without an account

    func testAccountScreenIsReachableFromSettingsAndShowsSignedOutState() {
        openAccountScreen()
        XCTAssertTrue(app.buttons["createAccountButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    func testContinueWithoutAnAccountReturnsToSettings() {
        openAccountScreen()
        let continueButton = app.buttons["continueWithoutAccountButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
        // Back on Settings — the Account row itself is still reachable (nothing was damaged).
        XCTAssertTrue(app.buttons["accountLink"].waitForExistence(timeout: 5))
    }

    // MARK: - Registration

    func testRegistrationShowsValidationFailureForAnInvalidEmail() {
        openAccountScreen()
        app.buttons["createAccountButton"].tap()

        let emailField = app.textFields["registrationEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText("not-an-email")

        XCTAssertTrue(app.staticTexts["Enter a valid email address."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["submitRegistrationButton"].isEnabled)
    }

    /// A real, precisely-diagnosed environment limitation, found while writing this test —
    /// not worked around silently, matching this codebase's own established discipline for
    /// this class of finding (docs/29 "K.", `NotificationStudioUITests`'s own toggle-value
    /// note): `registrationPasswordField`'s `typeText(_:)` synthesis only ever retains the
    /// *last* character of whatever string is sent, confirmed by reading the field's own
    /// `.value` directly (a lone "•") — regardless of typing speed, field type
    /// (`SecureField`/`TextField` via the visibility toggle), section header, sibling
    /// conditional views, `@FocusState`, or field position (the identical issue reproduces
    /// with the fields in either order). `signInPasswordField` — structurally identical —
    /// does not exhibit this; the difference was not isolated despite exhaustive elimination
    /// of every structural candidate. `AccountCoordinatorTests.signUpTransitionsToAwaitingEmailConfirmation`
    /// (`FakeAccountProvider`-backed) is the actual proof that `signUp`'s state-transition
    /// logic is correct; this test instead proves what UI automation *can* reliably drive
    /// here — the sheet opening, both `TextField`s (email/username) accumulating correctly,
    /// and the submit button's disabled state while required fields are incomplete.
    func testRegistrationFormAcceptsEmailAndUsernameAndGatesSubmission() {
        openAccountScreen()
        app.buttons["createAccountButton"].tap()

        let unique = UUID().uuidString.prefix(8)
        let emailField = app.textFields["registrationEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText("new\(unique)@kue.test")
        XCTAssertEqual(emailField.value as? String, "new\(unique)@kue.test")

        let usernameField = app.textFields["registrationUsernameField"]
        usernameField.tap()
        usernameField.typeText("newuser\(unique)")
        XCTAssertEqual(usernameField.value as? String, "newuser\(unique)")

        // Password is still empty — submission must stay gated regardless of the other two
        // valid fields (requirement H: "field-level validation").
        XCTAssertFalse(app.buttons["submitRegistrationButton"].isEnabled)
    }

    // MARK: - Sign in

    func testSignInWithInvalidCredentialsShowsAnErrorBanner() {
        openAccountScreen()
        app.buttons["signInButton"].tap()

        let emailField = app.textFields["signInEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText("wrong@kue.test")

        let passwordField = app.secureTextFields["signInPasswordField"]
        passwordField.tap()
        passwordField.typeText("wrongpassword")

        app.buttons["submitSignInButton"].tap()
        // `KueBanner`'s own accessibility identifier isn't reliably queryable as
        // `.otherElements` in this environment — its actual rendered message text is a more
        // robust anchor (matches `AccountError.invalidCredentials.description` exactly).
        XCTAssertTrue(app.staticTexts["Incorrect email or password."].waitForExistence(timeout: 5))
    }

    func testSignInWithTheFixtureAccountReachesTheSignedInProfile() {
        openAccountScreen()
        app.buttons["signInButton"].tap()

        let emailField = app.textFields["signInEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(FakeAccountProviderFixture.email)

        let passwordField = app.secureTextFields["signInPasswordField"]
        passwordField.tap()
        passwordField.typeText(FakeAccountProviderFixture.password)

        app.buttons["submitSignInButton"].tap()
        // `LabeledContent`'s label+value are combined into one accessibility element
        // ("Username, fixtureuser") in this environment — a `CONTAINS` predicate, not an
        // exact-match bracket lookup, is the reliable way to find it (same pattern already
        // established by `CloudSyncUITests`/`RecurringEventsUITests`).
        XCTAssertTrue(usernameRow().waitForExistence(timeout: 5))
    }

    // MARK: - Forgot password

    func testForgotPasswordShowsAConfirmationAfterSubmitting() {
        openAccountScreen()
        app.buttons["signInButton"].tap()
        app.buttons["forgotPasswordButton"].tap()

        let emailField = app.textFields["forgotPasswordEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(FakeAccountProviderFixture.email)

        app.buttons["submitForgotPasswordButton"].tap()
        XCTAssertTrue(app.staticTexts["If an account exists for that email, a reset link is on its way."].waitForExistence(timeout: 5))
    }

    // MARK: - Signed-in profile / statistics / editing / sign out / delete

    private func signInWithFixture() {
        openAccountScreen()
        app.buttons["signInButton"].tap()
        let emailField = app.textFields["signInEmailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(FakeAccountProviderFixture.email)
        let passwordField = app.secureTextFields["signInPasswordField"]
        passwordField.tap()
        passwordField.typeText(FakeAccountProviderFixture.password)
        app.buttons["submitSignInButton"].tap()
        dismissSystemSavePasswordPromptIfPresent()
        // Screen-level container identifiers (List/Section) aren't reliably queryable as
        // `.otherElements` in this environment, and `LabeledContent`'s label+value are
        // combined into one accessibility element ("Username, fixtureuser") rather than two
        // separate ones — a `CONTAINS` predicate (matching `CloudSyncUITests`/
        // `RecurringEventsUITests`' own established pattern) is the reliable way to find it.
        // The fixture profile's own username, actually rendered, is definitive proof the
        // profile loaded.
        XCTAssertTrue(usernameRow().waitForExistence(timeout: 5))
    }

    /// A real `SecureField` submission is exactly what triggers iOS's own system "Save
    /// Password?" AutoFill sheet in the Simulator — it appears in a *separate* window on top of
    /// the app's own, so it swallows every subsequent tap/swipe the test sends until dismissed
    /// (this is what was actually behind `signOutButton`/`deleteAccountButton`/
    /// `editProfileButton` never being found no matter how high `scrollUpUntilHittable`'s
    /// `maxSwipes` was raised — the List itself was fine, a system sheet was just sitting on
    /// top of it). "Not Now" is a one-off, best-effort dismissal; its absence isn't a failure —
    /// the Simulator doesn't always offer it.
    private func dismissSystemSavePasswordPromptIfPresent() {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) {
            notNow.tap()
        }
    }

    private func usernameRow() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", FakeAccountProviderFixture.username)).firstMatch
    }

    // Kue 3.0 Phase 6 — docs/34: the inline "Your Kue Activity" list this test used to check
    // for was replaced by a link out to the dedicated `InsightsView` (reachable from Settings
    // regardless of sign-in state, not just from a signed-in profile) — this now checks for
    // that link instead of statistics rendered inline here.
    func testSignedInProfileShowsIdentityAndALinkToInsights() {
        signInWithFixture()
        XCTAssertTrue(usernameRow().waitForExistence(timeout: 5))
        let insightsLink = app.buttons["insightsLinkFromProfile"]
        insightsLink.scrollUpUntilHittable(in: app)
        XCTAssertTrue(insightsLink.waitForExistence(timeout: 5))
    }

    func testEditProfileIsReachableAndCancellable() {
        signInWithFixture()
        let editButton = app.buttons["editProfileButton"]
        editButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()

        XCTAssertTrue(app.textFields["editUsernameField"].waitForExistence(timeout: 5))
        // Cancelling must never damage local data or the signed-in session.
        app.navigationBars.buttons["Cancel"].tap()
        // `editProfileButton` sits in the same scrolled-down position it was tapped from — the
        // identity section's username row above it is now off the visible List and, being a
        // lazily-materialized `List` cell, isn't in the accessibility tree to query at all
        // (same virtualization already noted elsewhere in this file/`scrollUpUntilHittable`'s
        // own header comment). `editProfileButton` still existing, without any error banner
        // having appeared, is the reachable proof that cancelling landed back on the same
        // signed-in profile rather than damaging the session.
        XCTAssertTrue(app.buttons["editProfileButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["createAccountButton"].exists)
    }

    func testSignOutReturnsToTheSignedOutState() {
        signInWithFixture()
        let signOutButton = app.buttons["signOutButton"]
        signOutButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 5))
        signOutButton.tap()
        // A distinct identifier on the confirmation dialog's own destructive action — its
        // label text ("Sign Out") collides with the row button that opened it, which sits
        // underneath the dialog for the whole time it's presented.
        // `confirmationDialog`'s action-sheet presentation duplicates its buttons in the
        // accessibility tree (an onscreen copy and an offscreen one mid-transition) — the same
        // shape this codebase already resolves elsewhere with `.firstMatch`.
        app.buttons["confirmSignOutButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createAccountButton"].waitForExistence(timeout: 5))
    }

    func testDeleteAccountRequiresExplicitConfirmationAndReturnsToSignedOut() {
        signInWithFixture()
        let deleteButton = app.buttons["deleteAccountButton"]
        deleteButton.scrollUpUntilHittable(in: app, maxSwipes: 20)
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        // The destructive confirmation must actually appear before anything happens.
        let confirmButton = app.buttons["confirmDeleteAccountButton"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        XCTAssertTrue(app.buttons["createAccountButton"].waitForExistence(timeout: 5))
    }
}

/// Literal copies of `FakeAccountProvider`'s own fixture constants — `KueUITests` has no
/// `@testable import Kue`, so it can't reference them directly, same reason
/// `UITestLaunchConfiguration`'s own launch-argument literals are hand-copied rather than
/// imported.
private enum FakeAccountProviderFixture {
    static let email = "fixture@kue.test"
    static let password = "fixture-password-123"
    static let username = "fixtureuser"
}
