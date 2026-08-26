//
//  ShareContent.swift
//  Kue
//
//  See docs/01-vision-and-scope.md "Share Sheet (text/URL only...)" and docs/13-error-
//  handling.md "Network failure" / "Invalid AI response". Requirement 2 (Phase 10 / M9):
//  "Extract and normalize extension-item content safely, including multiple/unsupported
//  attachments and load failures." Pure Foundation + a small protocol seam around
//  `NSItemProvider` — no `NSExtensionContext`/UIKit here, so this is independently testable
//  the same way every other DI seam in this codebase is (NotificationScheduling,
//  BackgroundTaskScheduling, ...).
//

import Foundation
import UniformTypeIdentifiers

/// One extension-item attachment, already loaded and classified. `nil`/failure states are
/// modeled explicitly rather than thrown, since a share can legitimately carry a mix of
/// supported and unsupported attachments — the normalizer below decides what to do with the
/// whole set, not any single attachment in isolation.
/// `nonisolated` — otherwise this module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// makes its `Equatable` conformance MainActor-isolated too, unusable from Swift Testing's
/// `#expect` in a non-`@MainActor` test body (see AGENTS.md's concurrency note).
nonisolated enum SharedAttachmentContent: Equatable {
    case text(String)
    case url(URL)
    /// Recognized as present but not a type Kue extracts from (e.g. an image).
    case unsupported
    /// A type Kue does extract from, but loading it threw or returned something unusable.
    case loadFailed
}

/// The minimal `NSItemProvider` surface this file needs — lets tests supply attachments
/// without constructing a real `NSItemProvider`/`NSExtensionItem`. Not `Sendable`-constrained
/// — everything here runs on the main actor already (a SwiftUI `.task`), so there's no need
/// to fight `NSSecureCoding`'s non-`Sendable` boxed values for a guarantee nothing uses.
nonisolated protocol ShareItemProviding {
    func hasItem(conformingTo typeIdentifier: String) -> Bool
    func loadItem(forTypeIdentifier typeIdentifier: String) async -> Result<NSSecureCoding, Error>
}

/// `nonisolated` — its stored `let` type identifiers and pure classification logic don't
/// need MainActor, and tests call it from a non-`@MainActor` body (see AGENTS.md's
/// concurrency note).
nonisolated enum ShareContentLoader {
    static let urlTypeIdentifier = UTType.url.identifier
    static let textTypeIdentifier = UTType.plainText.identifier

    /// Safely resolves one attachment: checks type conformance before ever attempting a
    /// load (requirement: "unsupported attachments"), and turns a thrown/unusable load into
    /// `.loadFailed` rather than propagating an error out of this pure classification step
    /// (requirement: "load failures").
    static func loadAttachment(_ provider: ShareItemProviding) async -> SharedAttachmentContent {
        if provider.hasItem(conformingTo: urlTypeIdentifier) {
            switch await provider.loadItem(forTypeIdentifier: urlTypeIdentifier) {
            case .success(let value):
                if let url = value as? URL { return .url(url) }
                if let nsURL = value as? NSURL { return .url(nsURL as URL) }
                return .loadFailed
            case .failure:
                return .loadFailed
            }
        }
        if provider.hasItem(conformingTo: textTypeIdentifier) {
            switch await provider.loadItem(forTypeIdentifier: textTypeIdentifier) {
            case .success(let value):
                if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .text(text)
                }
                if let nsString = value as? NSString {
                    let text = nsString as String
                    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .loadFailed : .text(text)
                }
                return .loadFailed
            case .failure:
                return .loadFailed
            }
        }
        return .unsupported
    }

    /// Requirement: "multiple ... attachments" — a share can carry several `NSItemProvider`s
    /// (e.g. a URL plus a text summary); every one is loaded and classified independently,
    /// sequentially (extension items are typically one or two attachments, never enough to
    /// need concurrency here).
    static func loadAll(_ providers: [ShareItemProviding]) async -> [SharedAttachmentContent] {
        var results: [SharedAttachmentContent] = []
        for provider in providers {
            results.append(await loadAttachment(provider))
        }
        return results
    }
}

/// What the share flow should actually do, once every attachment has been classified.
/// `nonisolated` for the same reason as `SharedAttachmentContent` above.
nonisolated enum SharedContentResult: Equatable {
    case url(URL)
    case text(String)
    /// Nothing recognized (e.g. only an image attachment) — fall back to an empty manual form.
    case unsupported
    /// Something recognized broke while loading — fall back to an empty manual form, same as
    /// `.unsupported`, but distinguished so the UI can show a more specific message.
    case loadFailed
}

nonisolated enum ShareContentNormalizer {
    /// Prefers a URL over plain text when both are present — Safari commonly attaches a
    /// page-title `String` alongside the page `URL`; the URL is the more useful, fetchable
    /// content (docs/11-privacy-and-offline.md: URL content is fetched, then parsed
    /// on-device same as any other NL text). `.loadFailed` only wins over `.unsupported` — an
    /// attempt that broke is more specific/actionable than "nothing recognized at all."
    static func normalize(_ attachments: [SharedAttachmentContent]) -> SharedContentResult {
        for attachment in attachments {
            if case .url(let url) = attachment { return .url(url) }
        }
        for attachment in attachments {
            if case .text(let text) = attachment { return .text(text) }
        }
        if attachments.contains(.loadFailed) { return .loadFailed }
        return .unsupported
    }
}
