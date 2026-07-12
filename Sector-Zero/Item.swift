//
//  Item.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
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
