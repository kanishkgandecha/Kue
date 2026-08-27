//
//  EventCard.swift
//  Kue
//
//  Kue 2.0 Phase 7 — Design System, requirement 13's "improved event cards/rows." Replaces
//  `EventRow`'s plain `HStack` with a clearer hierarchy: type icon, title, date/type
//  subtitle, a status badge, and — for an event with tasks — a compact preparation-progress
//  readout. Kept as a plain `List` row (not a card floating in its own glass container):
//  requirement 3/10 — glass is for controls/navigation, not every content row in a long
//  scrolling list, and a `List` already gives rows the platform's own selection/swipe/
//  separator behavior for free.
//
//  Preserves `EventRow`'s exact accessibility identifier scheme (`eventRow-<title>`) —
//  requirement 13's "retain stable automation identifiers where possible" / requirement 35.
//

import SwiftUI
import SwiftData

struct EventCard: View {
    @Bindable var event: KueEvent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: EventStatus {
        EventStatusEngine.derive(for: event)
    }

    private var style: KueStatusStyle {
        KueStatusStyle.forEvent(event, status: status)
    }

    private var dateText: String {
        let format: Date.FormatStyle = event.isAllDay
            ? .dateTime.month().day().year()
            : .dateTime.month().day().year().hour().minute()
        return event.startDate.formatted(format)
    }

    private var typeIcon: String {
        switch event.eventType {
        case .generic: return "calendar"
        case .deadline: return "clock.badge.exclamationmark"
        case .exam: return "book.closed"
        case .interview: return "person.crop.circle.badge.questionmark"
        case .trip: return "airplane"
        }
    }

    /// Requirement 13 — progress only shown where it's meaningful: an event with generated
    /// tasks, not yet fully complete, still upcoming enough to matter.
    private var showsProgress: Bool {
        !event.tasks.isEmpty && status != .completed && status != .cancelled && status != .archived
    }

    var body: some View {
        HStack(alignment: .top, spacing: KueSpacing.md) {
            Image(systemName: typeIcon)
                .font(.system(size: KueIconSize.medium))
                .foregroundStyle(status == .cancelled ? KueColor.disabled : KueColor.accent)
                .frame(width: KueIconSize.large, height: KueIconSize.large)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: KueSpacing.xs) {
                Text(event.title)
                    .font(KueTypography.cardTitle)
                    .foregroundStyle(KueColor.primaryText)
                    .strikethrough(status == .cancelled)
                    .lineLimit(2)
                    // Requirement 38 — long/localized titles must not truncate unreadably at
                    // accessibility sizes; 2 lines plus the row's own natural height gives
                    // large Dynamic Type room before anything is cut.
                    .minimumScaleFactor(1)

                Text("\(event.eventType.displayName) · \(dateText)")
                    .font(KueTypography.cardSubtitle)
                    .foregroundStyle(KueColor.secondaryText)
                    .lineLimit(2)

                if showsProgress {
                    PreparationProgressView(
                        completedCount: event.tasks.filter(\.isCompleted).count,
                        totalCount: event.tasks.count
                    )
                    .padding(.top, KueSpacing.xxs)
                }
            }

            Spacer(minLength: KueSpacing.sm)

            EventStatusBadge(style: style)
        }
        .padding(.vertical, KueSpacing.xs)
        .kueAnimation(reduceMotion: reduceMotion, value: status)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("eventRow-\(event.title)")
    }
}

#Preview("Event Cards") {
    let container = ModelContainerFactory.makeInMemory()
    let event = KueEvent(title: "Product Design Interview", eventType: .interview, startDate: .now.addingTimeInterval(3600), estimatedDurationMinutes: 60, source: .manual)
    container.mainContext.insert(event)
    let task = KueTask(event: event, title: "Review portfolio", dueDate: .now, isCompleted: true, offsetLabel: "1 day before")
    container.mainContext.insert(task)
    event.tasks = [task]
    return List {
        EventCard(event: event)
    }
    .modelContainer(container)
}
