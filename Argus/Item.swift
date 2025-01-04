//
//  Item.swift
//  Argus
//
//  Created by Jeremy Andrews on 04/01/25.
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
