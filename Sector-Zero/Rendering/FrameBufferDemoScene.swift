//
//  FrameBufferDemoScene.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import Foundation

final class FrameBufferDemoScene {
    func render(into frameBuffer: FrameBuffer, time: TimeInterval) {
        frameBuffer.clear()
        drawStaticGeometry(in: frameBuffer)
        drawDiagonalLine(in: frameBuffer)
        drawBlinkingCursor(in: frameBuffer, time: time)
        drawBouncingSquare(in: frameBuffer, time: time)
    }

    private func drawStaticGeometry(in frameBuffer: FrameBuffer) {
        frameBuffer.fillRect(x: 18, y: 18, width: 88, height: 34, color: .dimGreen)
        frameBuffer.fillRect(x: 22, y: 22, width: 80, height: 26, color: .green)

        frameBuffer.fillRect(x: 126, y: 36, width: 52, height: 58, color: .blue)
        frameBuffer.fillRect(x: 196, y: 26, width: 72, height: 22, color: .amber)
        frameBuffer.fillRect(x: 230, y: 70, width: 42, height: 46, color: .red)

        frameBuffer.drawHorizontalLine(x: 18, y: 132, length: 250, color: .dimGreen)
        frameBuffer.drawVerticalLine(x: 286, y: 18, length: 118, color: .dimGreen)
    }

    private func drawDiagonalLine(in frameBuffer: FrameBuffer) {
        let length = min(frameBuffer.width, frameBuffer.height)

        for offset in 0..<length {
            frameBuffer.setPixel(x: 42 + offset, y: 150 - (offset / 2), color: .green)
        }
    }

    private func drawBlinkingCursor(in frameBuffer: FrameBuffer, time: TimeInterval) {
        let blink = 0.5 + 0.5 * sin(time * 5.2)
        guard blink > 0.28 else {
            return
        }

        frameBuffer.fillRect(x: 24, y: 66, width: 9, height: 15, color: .green)
    }

    private func drawBouncingSquare(in frameBuffer: FrameBuffer, time: TimeInterval) {
        let squareSize = 10
        let travelWidth = frameBuffer.width - squareSize - 24
        let travelHeight = frameBuffer.height - squareSize - 28
        let x = 12 + pingPong(time * 54, limit: travelWidth)
        let y = 14 + pingPong(time * 31, limit: travelHeight)

        frameBuffer.fillRect(x: x, y: y, width: squareSize, height: squareSize, color: .amber)
    }

    private func pingPong(_ value: TimeInterval, limit: Int) -> Int {
        guard limit > 0 else {
            return 0
        }

        let period = Double(limit * 2)
        let wrapped = value.truncatingRemainder(dividingBy: period)
        let distance = wrapped <= Double(limit) ? wrapped : period - wrapped
        return Int(distance.rounded())
    }
}
