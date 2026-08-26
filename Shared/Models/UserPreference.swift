//
//  UserPreference.swift
//  Kue
//
//  See docs/03-data-model.md "UserPreference" — singleton settings row. No widget-size
//  preference: widget family isn't app-settable, default or otherwise (docs/14-open-questions.md).
//

import Foundation
import SwiftData

/// docs/08-notifications.md "User control over intensity" — `.standard` is the documented default.
enum NotificationIntensity: String, Codable, CaseIterable {
    case minimal, standard, all
}

@Model
final class UserPreference {
    var id: UUID
    var notificationIntensity: NotificationIntensity
    /// User can force manual-only entry.
    var aiParsingEnabled: Bool

    init(
        id: UUID = UUID(),
        notificationIntensity: NotificationIntensity = .standard,
        aiParsingEnabled: Bool = true
    ) {
        self.id = id
        self.notificationIntensity = notificationIntensity
        self.aiParsingEnabled = aiParsingEnabled
    }
}
