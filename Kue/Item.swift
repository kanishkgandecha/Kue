//
//  Item.swift
//  Kue
//
//  Created by Kanishk Gandecha on 25/08/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
