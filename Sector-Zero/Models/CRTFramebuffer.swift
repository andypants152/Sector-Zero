//
//  CRTFramebuffer.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import Foundation

struct CRTFramebuffer: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
