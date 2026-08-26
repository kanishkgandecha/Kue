//
//  RecurrenceRule.swift
//  Kue
//
//  See docs/03-data-model.md "KueEvent" — `recurrence` is post-V1 and always nil in V1.
//  Reserved now only so KueEvent's schema doesn't need a breaking migration later.
//

import Foundation

struct RecurrenceRule: Codable {}
