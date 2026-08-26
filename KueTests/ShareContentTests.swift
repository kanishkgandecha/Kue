//
//  ShareContentTests.swift
//  KueTests
//
//  See docs/01-vision-and-scope.md "Share Sheet (text/URL only...)" — Phase 10 (M9)
//  requirement 9: text, URL, malformed provider data, unsupported content. Pure — a fake
//  `ShareItemProviding` stands in for `NSItemProvider`, so nothing here touches a real
//  extension context.
//

import Testing
import Foundation
@testable import Kue

private struct FakeItemProvider: ShareItemProviding {
    var conformingTypes: Set<String>
    var result: Result<NSSecureCoding, Error>

    func hasItem(conformingTo typeIdentifier: String) -> Bool {
        conformingTypes.contains(typeIdentifier)
    }

    func loadItem(forTypeIdentifier typeIdentifier: String) async -> Result<NSSecureCoding, Error> {
        result
    }
}

private struct StubError: Error {}

struct ShareContentTests {
    // MARK: - Text (requirement 9: "text")

    @Test func loadsAPlainTextAttachment() async {
        let provider = FakeItemProvider(
            conformingTypes: [ShareContentLoader.textTypeIdentifier],
            result: .success("Interview Friday at 10" as NSString)
        )
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .text("Interview Friday at 10"))
    }

    // MARK: - URL (requirement 9: "URL")

    @Test func loadsAURLAttachment() async {
        let url = URL(string: "https://example.com/event")!
        let provider = FakeItemProvider(
            conformingTypes: [ShareContentLoader.urlTypeIdentifier],
            result: .success(url as NSURL)
        )
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .url(url))
    }

    // MARK: - Malformed provider data (requirement 9)

    @Test func aThrowingLoadIsReportedAsLoadFailedNotPropagated() async {
        let provider = FakeItemProvider(
            conformingTypes: [ShareContentLoader.textTypeIdentifier],
            result: .failure(StubError())
        )
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .loadFailed)
    }

    @Test func aURLTypeThatResolvesToTheWrongValueTypeIsLoadFailed() async {
        // Conforms to the URL type identifier but the provider hands back something that
        // isn't actually a URL — malformed provider data, not a crash.
        let provider = FakeItemProvider(
            conformingTypes: [ShareContentLoader.urlTypeIdentifier],
            result: .success("not a url" as NSString)
        )
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .loadFailed)
    }

    @Test func emptyTextIsLoadFailedNotAnEmptyDraft() async {
        let provider = FakeItemProvider(
            conformingTypes: [ShareContentLoader.textTypeIdentifier],
            result: .success("   " as NSString)
        )
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .loadFailed)
    }

    // MARK: - Unsupported content (requirement 9)

    @Test func anAttachmentConformingToNeitherKnownTypeIsUnsupported() async {
        let provider = FakeItemProvider(conformingTypes: ["public.image"], result: .failure(StubError()))
        let result = await ShareContentLoader.loadAttachment(provider)
        #expect(result == .unsupported)
    }

    // MARK: - Multiple attachments

    @Test func loadAllClassifiesEveryAttachmentIndependently() async {
        let providers: [ShareItemProviding] = [
            FakeItemProvider(conformingTypes: [ShareContentLoader.urlTypeIdentifier], result: .success(URL(string: "https://example.com")! as NSURL)),
            FakeItemProvider(conformingTypes: [ShareContentLoader.textTypeIdentifier], result: .success("a title" as NSString)),
            FakeItemProvider(conformingTypes: ["public.image"], result: .failure(StubError())),
        ]
        let results = await ShareContentLoader.loadAll(providers)
        #expect(results == [.url(URL(string: "https://example.com")!), .text("a title"), .unsupported])
    }

    // MARK: - Normalization priority

    @Test func normalizePrefersURLOverText() {
        let result = ShareContentNormalizer.normalize([.text("a title"), .url(URL(string: "https://example.com")!)])
        #expect(result == .url(URL(string: "https://example.com")!))
    }

    @Test func normalizeFallsBackToTextWhenNoURLPresent() {
        let result = ShareContentNormalizer.normalize([.unsupported, .text("Interview Friday at 10")])
        #expect(result == .text("Interview Friday at 10"))
    }

    @Test func normalizeReportsLoadFailedOverUnsupportedWhenBothPresent() {
        let result = ShareContentNormalizer.normalize([.unsupported, .loadFailed])
        #expect(result == .loadFailed)
    }

    @Test func normalizeReportsUnsupportedWhenNothingUsableWasFound() {
        let result = ShareContentNormalizer.normalize([.unsupported, .unsupported])
        #expect(result == .unsupported)
    }

    @Test func normalizeOfEmptyAttachmentListIsUnsupported() {
        #expect(ShareContentNormalizer.normalize([]) == .unsupported)
    }
}
