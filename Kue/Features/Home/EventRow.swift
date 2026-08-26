//
//  EventRow.swift
//  Kue
//
//  A single Home list row — title, date, and a status-derived subtitle/icon.
//

import SwiftUI

struct EventRow: View {
    let event: KueEvent

    private var status: EventStatus {
        EventStatusEngine.derive(for: event)
    }

    private var dateText: String {
        let style: Date.FormatStyle = event.isAllDay
            ? .dateTime.month().day().year()
            : .dateTime.month().day().year().hour().minute()
        return event.startDate.formatted(style)
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(status == .cancelled ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading) {
                Text(event.title)
                    .font(.body)
                    .strikethrough(status == .cancelled)
                Text("\(event.eventType.displayName) · \(dateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .cancelled {
                Text("Cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("eventRow-\(event.title)")
    }

    private var icon: String {
        switch event.eventType {
        case .generic: return "calendar"
        case .deadline: return "clock.badge.exclamationmark"
        case .exam: return "book.closed"
        case .interview: return "person.crop.circle.badge.questionmark"
        case .trip: return "airplane"
        }
    }
}
