//
//  SupabaseConfiguration.swift
//  Kue
//
//  Kue 3.0 Phase 4 — docs/32 "Supabase configuration." The one place the Supabase project URL
//  and client-safe publishable/anonymous key are read from — every other file that needs them
//  reads through `SupabaseConfiguration.current`, never a second copy of the literal values.
//
//  Values live in `SupabaseConfig.plist` (this same folder), a checked-in resource file — the
//  anon/publishable key is explicitly *designed* by Supabase to be client-safe (it only ever
//  grants what a signed-out/signed-in user's own Row Level Security policies already allow;
//  see docs/32 "Privacy"), the same trust model a Firebase `apiKey` or a Stripe publishable
//  key already has. This is never a service-role key or any other secret — those never belong
//  in an Apple target at all (requirement E).
//
//  `SupabaseConfig.plist` contains the Kue Development project's client-safe URL and
//  publishable key. `current` still returns `nil` whenever the resource is missing, carries
//  placeholder values, or either value fails a basic shape check — the "missing configuration
//  must produce a truthful unavailable state, not a crash" requirement.
//
//  Bundled once, under `Shared/`, into every one of the five targets that synchronize that
//  folder (Kue, KueWidget, KueShare, KueMac, and — via `@testable import Kue` — KueTests) —
//  each gets its own copy of the same file, satisfying "must not be duplicated across source
//  files" (one source of truth, not one literal per target).
//

import Foundation

nonisolated struct SupabaseConfiguration: Equatable {
    var url: URL
    var anonKey: String

    /// `nil` when `SupabaseConfig.plist` is missing, still carries its placeholder values, or
    /// either value doesn't pass a basic shape check (a real `https://` URL; a key that at
    /// least looks like one, not empty/placeholder text). Every account-feature call site
    /// reads this, never the raw plist, and treats `nil` as `AccountUnavailableReason
    /// .configurationMissing` — never a crash, never a silent fallback to some other value.
    static var current: SupabaseConfiguration? {
        guard
            let plistURL = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
            let data = try? Data(contentsOf: plistURL),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
            let urlString = dictionary["SUPABASE_URL"],
            let anonKey = dictionary["SUPABASE_ANON_KEY"]
        else { return nil }
        return make(urlString: urlString, anonKey: anonKey)
    }

    /// Split out from `current` so a unit test can exercise the exact same validation logic
    /// against literal strings, never a real bundled resource.
    static func make(urlString: String, anonKey: String) -> SupabaseConfiguration? {
        guard
            let url = URL(string: urlString), url.scheme == "https", let host = url.host, !host.isEmpty,
            !urlString.contains("YOUR_"), !urlString.isEmpty,
            !anonKey.isEmpty, !anonKey.contains("YOUR_"), anonKey.count > 20
        else { return nil }
        return SupabaseConfiguration(url: url, anonKey: anonKey)
    }
}
