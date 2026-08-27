//
//  CalendarDestinationPickerView.swift
//  Kue
//
//  Kue 2.0 Phase 4 — Apple Calendar Integration. Requirement 18: "select a writable
//  destination calendar" before exporting. A small standalone sheet so
//  `EventDetailView` stays thin, same rationale as `EditScheduleView` being its own file.
//

import SwiftUI

struct CalendarDestinationPickerView: View {
    let calendars: [KueWritableCalendar]
    var onSelect: (KueWritableCalendar) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if calendars.isEmpty {
                    ContentUnavailableView(
                        "No Writable Calendars",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Kue doesn't have a calendar it can add events to.")
                    )
                } else {
                    List(calendars) { calendar in
                        Button {
                            onSelect(calendar)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("calendarDestination-\(calendar.calendarIdentifier)")
                    }
                    .accessibilityIdentifier("calendarDestinationList")
                }
            }
            .navigationTitle("Add to Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
