//
//  MacCalendarDestinationPickerView.swift
//  KueMac
//
//  Kue 3.0 Phase 1 cleanup — a small native Mac picker for "Add to Apple Calendar," mirroring
//  `Kue/Features/Detail/CalendarDestinationPickerView.swift` (iOS)'s own purpose without
//  reusing that file directly (it's a `NavigationStack`/`List` sheet tuned for an iPhone
//  screen, not a Mac window). Reuses `CalendarProviding.writableCalendars()`/
//  `KueWritableCalendar` (Shared/) verbatim — nothing here re-derives which calendars are
//  writable.
//

import SwiftUI

struct MacCalendarDestinationPickerView: View {
    let calendars: [KueWritableCalendar]
    var onSelect: (KueWritableCalendar) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if calendars.isEmpty {
                    ContentUnavailableView(
                        "No Writable Calendars",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("No calendar on this Mac currently accepts new events.")
                    )
                } else {
                    ForEach(calendars) { calendar in
                        Button {
                            onSelect(calendar)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose a Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
