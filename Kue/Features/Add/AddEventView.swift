//
//  AddEventView.swift
//  Kue
//
//  Placeholder sheet destination — docs/09-screens-and-ux.md "Add": manual form / NL text
//  entry land in Phase 2 (Event Management) and Phase 7 (Natural-Language AI) respectively.
//

import SwiftUI

struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Add Event",
                systemImage: "plus.circle",
                description: Text("Manual entry and natural-language input arrive in later phases.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AddEventView()
}
