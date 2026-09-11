//
//  AccountValidationTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Testing": "registration validation," "normalized username
//  validation." Pure — no networking, no ModelContext.
//

import Testing
@testable import Kue

struct AccountValidationTests {
    // MARK: - Email

    @Test func validEmailsPass() {
        #expect(AccountValidation.isValidEmail("a@b.com"))
        #expect(AccountValidation.isValidEmail("kanishk.gandecha09@gmail.com"))
        #expect(AccountValidation.isValidEmail("name+tag@sub.example.co"))
    }

    @Test func invalidEmailsFail() {
        #expect(!AccountValidation.isValidEmail(""))
        #expect(!AccountValidation.isValidEmail("no-at-sign"))
        #expect(!AccountValidation.isValidEmail("@nodomain.com"))
        #expect(!AccountValidation.isValidEmail("noname@"))
        #expect(!AccountValidation.isValidEmail("noname@nodot"))
        #expect(!AccountValidation.isValidEmail("has space@example.com"))
        #expect(!AccountValidation.isValidEmail("name@.com"))
        #expect(!AccountValidation.isValidEmail("name@com."))
    }

    // MARK: - Password

    @Test func passwordsMeetingMinimumLengthPass() {
        #expect(AccountValidation.isValidPassword("12345678"))
        #expect(AccountValidation.isValidPassword("a very long passphrase"))
    }

    @Test func shortPasswordsFail() {
        #expect(!AccountValidation.isValidPassword(""))
        #expect(!AccountValidation.isValidPassword("short1"))
        #expect(!AccountValidation.isValidPassword(String(repeating: "a", count: AccountValidation.minimumPasswordLength - 1)))
    }

    // MARK: - Username policy

    @Test func normalizeLowercasesAndTrims() {
        #expect(UsernamePolicy.normalize("  Kanishk  ") == "kanishk")
        #expect(UsernamePolicy.normalize("ALLCAPS") == "allcaps")
    }

    @Test func validUsernamesPass() {
        #expect(UsernamePolicy.isValid("kanishk"))
        #expect(UsernamePolicy.isValid("k_gandecha09"))
        #expect(UsernamePolicy.isValid("abc"))
        #expect(UsernamePolicy.isValid(String(repeating: "a", count: UsernamePolicy.maximumLength)))
    }

    @Test func tooShortUsernameIsRejected() {
        #expect(UsernamePolicy.validationError(for: "ab") != nil)
    }

    @Test func tooLongUsernameIsRejected() {
        #expect(UsernamePolicy.validationError(for: String(repeating: "a", count: UsernamePolicy.maximumLength + 1)) != nil)
    }

    @Test func usernameMustStartWithALetter() {
        #expect(UsernamePolicy.validationError(for: "1abc") != nil)
        #expect(UsernamePolicy.validationError(for: "_abc") != nil)
    }

    @Test func disallowedCharactersAreRejected() {
        #expect(UsernamePolicy.validationError(for: "abc def") != nil)
        #expect(UsernamePolicy.validationError(for: "abc-def") != nil)
        #expect(UsernamePolicy.validationError(for: "abc.def") != nil)
        #expect(UsernamePolicy.validationError(for: "abc@def") != nil)
    }

    @Test func consecutiveUnderscoresAreRejected() {
        #expect(UsernamePolicy.validationError(for: "abc__def") != nil)
    }

    @Test func trailingUnderscoreIsRejected() {
        #expect(UsernamePolicy.validationError(for: "abcdef_") != nil)
    }

    @Test func reservedNamesAreRejectedCaseInsensitively() {
        #expect(UsernamePolicy.validationError(for: "admin") != nil)
        #expect(UsernamePolicy.validationError(for: "ADMIN") != nil)
        #expect(UsernamePolicy.validationError(for: "Kue") != nil)
    }
}
