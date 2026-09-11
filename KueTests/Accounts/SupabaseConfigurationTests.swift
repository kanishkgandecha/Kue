//
//  SupabaseConfigurationTests.swift
//  KueTests
//
//  Kue 3.0 Phase 4 — docs/32 "Personal-build behavior": "missing configuration must produce a
//  truthful unavailable state, not a crash." Exercises `SupabaseConfiguration.make(_:_:)`
//  directly against literal strings — never the real bundled `SupabaseConfig.plist`, so this
//  passes identically whether or not the placeholder has been filled in yet.
//

import Testing
import Foundation
@testable import Kue

struct SupabaseConfigurationTests {
    @Test func aWellFormedURLAndKeyProduceAConfiguration() {
        let configuration = SupabaseConfiguration.make(urlString: "https://abcdefghijklmnop.supabase.co", anonKey: String(repeating: "a", count: 40))
        #expect(configuration != nil)
        #expect(configuration?.url.absoluteString == "https://abcdefghijklmnop.supabase.co")
    }

    @Test func thePlaceholderURLProducesNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "https://YOUR_PROJECT_REF.supabase.co", anonKey: String(repeating: "a", count: 40)) == nil)
    }

    @Test func thePlaceholderKeyProducesNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "https://abcdefghijklmnop.supabase.co", anonKey: "YOUR_SUPABASE_ANON_KEY") == nil)
    }

    @Test func emptyValuesProduceNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "", anonKey: "") == nil)
    }

    @Test func aNonHTTPSURLProducesNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "http://abcdefghijklmnop.supabase.co", anonKey: String(repeating: "a", count: 40)) == nil)
    }

    @Test func aMalformedURLProducesNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "not a url", anonKey: String(repeating: "a", count: 40)) == nil)
    }

    @Test func aSuspiciouslyShortKeyProducesNilConfiguration() {
        #expect(SupabaseConfiguration.make(urlString: "https://abcdefghijklmnop.supabase.co", anonKey: "short") == nil)
    }
}
