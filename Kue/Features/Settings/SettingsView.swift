//
//  SettingsView.swift
//  Kue
//
//  Placeholder push destination — docs/09-screens-and-ux.md "Settings": AI on/off,
//  notification intensity, appearance, and privacy controls arrive alongside the phases
//  that back them (AI in Phase 7, notifications in Phase 8, delete-everything whenever
//  Privacy is built out).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "Settings",
            systemImage: "gearshape",
            description: Text("AI, notifications, appearance, and privacy controls arrive in later phases.")
        )
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
