//
//  FrameBuffer.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import Foundation

struct FrameBufferColor: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    static let black = FrameBufferColor(red: 0, green: 0, blue: 0, alpha: 255)
    static let green = FrameBufferColor(red: 54, green: 230, blue: 112, alpha: 255)
    static let dimGreen = FrameBufferColor(red: 16, green: 88, blue: 42, alpha: 255)
    static let amber = FrameBufferColor(red: 214, green: 157, blue: 52, alpha: 255)
    static let red = FrameBufferColor(red: 184, green: 62, blue: 58, alpha: 255)
    static let blue = FrameBufferColor(red: 72, green: 122, blue: 210, alpha: 255)
}

final class FrameBuffer {
    let width: Int
    let height: Int

    private(set) var pixels: [UInt8]

    init(width: Int = 320, height: Int = 200, clearColor: FrameBufferColor = .black) {
        self.width = width
        self.height = height
        self.pixels = Array(repeating: 0, count: width * height * 4)
        clear(to: clearColor)
    }

    var bytesPerRow: Int {
        width * 4
    }

    func clear(to color: FrameBufferColor = .black) {
        for y in 0..<height {
            drawHorizontalLine(x: 0, y: y, length: width, color: color)
        }
    }

    func setPixel(x: Int, y: Int, color: FrameBufferColor) {
        guard contains(x: x, y: y) else {
            return
        }

        writePixelUnchecked(x: x, y: y, color: color)
    }

    func fillRect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, color: FrameBufferColor) {
        guard rectWidth > 0, rectHeight > 0 else {
            return
        }

        let startX = max(x, 0)
        let endX = min(x + rectWidth, width)
        let startY = max(y, 0)
        let endY = min(y + rectHeight, height)

        guard startX < endX, startY < endY else {
            return
        }

        for row in startY..<endY {
            drawHorizontalLine(x: startX, y: row, length: endX - startX, color: color)
        }
    }

    func drawHorizontalLine(x: Int, y: Int, length: Int, color: FrameBufferColor) {
        guard y >= 0, y < height, length > 0 else {
            return
        }

        let startX = max(x, 0)
        let endX = min(x + length, width)

        guard startX < endX else {
            return
        }

        for column in startX..<endX {
            writePixelUnchecked(x: column, y: y, color: color)
        }
    }

    func drawVerticalLine(x: Int, y: Int, length: Int, color: FrameBufferColor) {
        guard x >= 0, x < width, length > 0 else {
            return
        }

        let startY = max(y, 0)
        let endY = min(y + length, height)

        guard startY < endY else {
            return
        }

        for row in startY..<endY {
            writePixelUnchecked(x: x, y: row, color: color)
        }
    }

    private func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    private func writePixelUnchecked(x: Int, y: Int, color: FrameBufferColor) {
        let index = ((y * width) + x) * 4
        pixels[index] = color.red
        pixels[index + 1] = color.green
        pixels[index + 2] = color.blue
        pixels[index + 3] = color.alpha
    }
}
