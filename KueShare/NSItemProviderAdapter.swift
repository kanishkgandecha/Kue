//
//  NSItemProviderAdapter.swift
//  KueShare
//
//  Retroactive conformance living here (not Shared/) since it's real `NSItemProvider` glue,
//  only ever constructed from a real `NSExtensionContext` — see ShareContent.swift (Shared/)
//  for the protocol this satisfies and why it's abstracted at all (testability).
//

import Foundation

extension NSItemProvider: ShareItemProviding {
    func hasItem(conformingTo typeIdentifier: String) -> Bool {
        hasItemConformingToTypeIdentifier(typeIdentifier)
    }

    func loadItem(forTypeIdentifier typeIdentifier: String) async -> Result<NSSecureCoding, Error> {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }
                guard let secureItem = item else {
                    continuation.resume(returning: .failure(CocoaError(.coderReadCorrupt)))
                    return
                }
                continuation.resume(returning: .success(secureItem))
            }
        }
    }
}
